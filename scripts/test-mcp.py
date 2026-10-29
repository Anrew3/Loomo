"""Drives `crimp mcp` over stdio like an MCP client does, and checks the answers.

    python3 scripts/test-mcp.py Packages/CrimpKit/.build/debug/crimp /tmp/mcp-test          # file mode (quit Loomo first)
    python3 scripts/test-mcp.py /Applications/Loomo.app/Contents/MacOS/crimp /tmp/mcp-test --live

Without --live it needs Loomo's bridge to be unreachable (file mode). With --live it expects the harness at
<work dir>/live.loomo to be open in Loomo and checks that edits go there.
"""
import json, os, subprocess, sys

crimp, work = sys.argv[1], sys.argv[2]
live = "--live" in sys.argv
os.makedirs(work, exist_ok=True)
proc = subprocess.Popen([crimp, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
next_id = 0
failures = 0


def rpc(method, params=None, notify=False):
    global next_id
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        next_id += 1
        msg["id"] = next_id
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    if notify:
        return None
    line = proc.stdout.readline()
    reply = json.loads(line)
    assert reply.get("id") == next_id, f"reply id {reply.get('id')} != {next_id}"
    return reply


def check(label, ok, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"  -> {detail}"))
    if not ok:
        failures += 1


def tool(name, **args):
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    text = r["content"][0]["text"]
    try:
        body = json.loads(text)
    except json.JSONDecodeError:
        body = text
    return r.get("isError", False), body


# Handshake
r = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})["result"]
check("initialize negotiates 2025-06-18", r["protocolVersion"] == "2025-06-18", r)
check("advertises tools", "tools" in r["capabilities"], r)
check("has instructions", "C1:2" in r.get("instructions", ""), r)
r = rpc("initialize", {"protocolVersion": "1999-01-01"})["result"]
check("unknown version falls back to latest", r["protocolVersion"] == "2025-06-18", r)
check("notification gets no reply", rpc("notifications/initialized", notify=True) is None)
check("ping", rpc("ping")["result"] == {})
check("unknown method is -32601", rpc("nope/nope")["error"]["code"] == -32601)

# Tool list
tools = {t["name"]: t for t in rpc("tools/list")["result"]["tools"]}
for name in ["list_documents", "open_harness", "describe_harness", "get_harness", "check_harness", "add_connector",
             "add_wire", "set_wire", "rename_connector", "rename_cavity", "move_item", "remove_items", "pass_through"]:
    check(f"tool {name} listed", name in tools)
aw = tools["add_wire"]["inputSchema"]
check("add_wire requires from and to", set(aw.get("required", [])) == {"from", "to"}, aw.get("required"))
check("add_wire has double_crimp boolean", aw["properties"].get("double_crimp", {}).get("type") == "boolean", aw["properties"].keys())
check("add_connector kind is an enum", "housing" in tools["add_connector"]["inputSchema"]["properties"]["kind"].get("enum", []))
check("remove_items is destructive", tools["remove_items"]["annotations"]["destructiveHint"] is True)
check("describe_harness is read-only", tools["describe_harness"]["annotations"]["readOnlyHint"] is True)
check("every tool takes document and file", all("file" in t["inputSchema"]["properties"] for n, t in tools.items() if n not in ("list_documents", "open_harness")))

target = os.path.join(work, "live.loomo" if live else "mcp.loomo")
if not live:
    if os.path.exists(target):
        os.remove(target)
    subprocess.run([crimp, "new", target], check=True, capture_output=True)
    err, body = tool("list_documents")
    check("list_documents reports Loomo not running", not err and body["loomoRunning"] is False, body)
    err, body = tool("describe_harness")
    check("no file and no Loomo is a clear error", err and "Loomo isn't running" in body, body)

mode = "live" if live else "file"
err, body = tool("describe_harness", file=target)
check(f"describe_harness ({mode})", not err and isinstance(body, str) and "Harness" in body, body)
err, body = tool("add_connector", file=target, mpn="GENERIC", description="MCP test plug", cavities=3, id="C42", x=1200, y=300)
check(f"add_connector ({mode})", not err and body["result"]["created"] == "C42" and body["mode"] == mode, body)
err, body = tool("add_splice", file=target, id="SP42", x=1300, y=300)
check(f"add_splice ({mode})", not err and body["result"]["created"] == "SP42", body)
err, body = tool("add_wire", file=target, **{"from": "C42:1", "to": "SP42", "size": "18awg", "color": "red/white", "id": "W420"})
check(f"add_wire ({mode})", not err and body["result"]["created"] == "W420" and "errors" in body["result"], body)
err, body = tool("add_wire", file=target, **{"from": "C42:1", "to": "SP42"})
check("occupied cavity is an error result", err and "already has a wire" in body, body)
err, body = tool("set_wire", file=target, wire="W420", signal="MCP_TEST", length="300mm")
check("set_wire", not err, body)
err, body = tool("rename_cavity", file=target, connector="C42", cavity="2", to="B")
check("rename_cavity", not err, body)
err, body = tool("move_item", file=target, id="C42", x=1250, y=320)
check("move_item", not err and body["result"]["moved"] == "C42", body)
err, body = tool("add_wire", file=target, bogus=1, **{"from": "C42:3", "to": "SP42"})
check("unknown argument is an error", err and "no argument bogus" in body, body)
err, body = tool("get_harness", file=target)
w = next((x for x in body["result"]["wires"] if x["id"] == "W420"), None) if not err else None
check("get_harness shows the edits", w is not None and w["signal"] == "MCP_TEST" and w["length"]["mm"] == 300, w)
err, body = tool("check_harness", file=target)
check("check_harness", not err and "issues" in body["result"], body)
err, body = tool("remove_items", file=target, ids=["W420", "SP42", "C42"])
check("remove_items", not err and body["result"]["removed"] == ["W420", "SP42", "C42"], body)
err, body = tool("no_such_tool")
check("unknown tool is an error result", err, body)

if not live:
    with open(target) as f:
        on_disk = json.load(f)
    check("file on disk is a valid harness", "connectors" in on_disk and not any(c["id"] == "C42" for c in on_disk["connectors"]))

proc.stdin.close()
proc.wait(timeout=10)
stderr = proc.stderr.read()
check("server exits cleanly at end of input", proc.returncode == 0, (proc.returncode, stderr[-500:]))
print(f"\n{'ALL PASSED' if failures == 0 else str(failures) + ' FAILED'}")
sys.exit(1 if failures else 0)
