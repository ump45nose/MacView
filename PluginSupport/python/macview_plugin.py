"""MacView 外部程序插件工具库（仅使用 Python 标准库）。"""

import json
import sys
import threading
import traceback


class RPCError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class _StorageProxy:
    def __init__(self, plugin):
        self._plugin = plugin

    def get(self, key):
        return self._plugin.call_host("mv.storageGet", [key])

    def set(self, key, value):
        return self._plugin.call_host("mv.storageSet", [key, value])

    def remove(self, key):
        return self._plugin.call_host("mv.storageRemove", [key])


class _MVProxy:
    def __init__(self, plugin):
        self._plugin = plugin
        self.storage = _StorageProxy(plugin)

    def __getattr__(self, name):
        def invoke(*args):
            return self._plugin.call_host("mv." + name, list(args))
        return invoke


class Plugin:
    def __init__(self):
        self._commands = {}
        self._source_listers = {}
        self._source_readers = {}
        self._filters = {}
        self._event_handler = None
        self._write_lock = threading.Lock()
        self._pending_lock = threading.Lock()
        self._next_id = 1
        self._pending = {}
        self._cancelled = set()
        self._init_info = {}
        self._shutdown = threading.Event()
        self.mv = _MVProxy(self)

    @property
    def init_info(self):
        return self._init_info

    def command(self, command_id):
        def decorator(fn):
            self._commands[command_id] = fn
            return fn
        return decorator

    def source_list(self, source_type):
        def decorator(fn):
            self._source_listers[source_type] = fn
            return fn
        return decorator

    def source_read(self, source_type):
        def decorator(fn):
            self._source_readers[source_type] = fn
            return fn
        return decorator

    def filter(self, filter_id):
        def decorator(fn):
            self._filters[filter_id] = fn
            return fn
        return decorator

    def on_event(self, fn):
        self._event_handler = fn
        return fn

    def is_cancelled(self, request_id):
        return request_id in self._cancelled

    def log(self, message, level="info"):
        self._send({"jsonrpc": "2.0", "method": "log", "params": {"level": level, "message": str(message)}})

    def call_host(self, method, params):
        event = threading.Event()
        holder = {}
        with self._pending_lock:
            req_id = "p-" + str(self._next_id)
            self._next_id += 1
            self._pending[req_id] = (event, holder)
        self._send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        event.wait()
        if "error" in holder:
            err = holder["error"]
            raise RPCError(err.get("code", -32000), err.get("message", "Host error"))
        return holder.get("result")

    def _send(self, payload):
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
        with self._write_lock:
            sys.stdout.write(line)
            sys.stdout.flush()

    def _handle_incoming(self, msg):
        method = msg.get("method")
        req_id = msg.get("id")
        params = msg.get("params")
        if params is None:
            params = {}
        try:
            if method == "initialize":
                self._init_info = params if isinstance(params, dict) else {}
                result = {}
            elif method == "command.run":
                cmd_id = params.get("command")
                fn = self._commands.get(cmd_id)
                if fn is None:
                    raise RPCError(-32601, "Unknown command: {}".format(cmd_id))
                result = fn(params.get("arguments") or {}, params.get("context") or {})
            elif method == "source.list":
                source = params.get("source") or {}
                fn = self._source_listers.get(source.get("type"))
                if fn is None:
                    raise RPCError(-32601, "Unknown source type: {}".format(source.get("type")))
                entries = fn(source, params.get("path") or [])
                result = entries if isinstance(entries, dict) and "entries" in entries else {"entries": entries}
            elif method == "source.read":
                source = params.get("source") or {}
                fn = self._source_readers.get(source.get("type"))
                if fn is None:
                    raise RPCError(-32601, "Source does not implement read: {}".format(source.get("type")))
                data = fn(source, params.get("path") or [], params.get("offset", 0), params.get("length", 0))
                result = data if isinstance(data, dict) and "data" in data else {"data": data}
            elif method == "filter.apply":
                flt_id = params.get("filter")
                fn = self._filters.get(flt_id)
                if fn is None:
                    raise RPCError(-32601, "Unknown filter: {}".format(flt_id))
                fn(params.get("input"), params.get("output"), params.get("parameters") or {})
                result = {}
            elif method == "event":
                if self._event_handler is not None:
                    self._event_handler(params.get("name"), params.get("payload") or {}, params.get("session"))
                return
            else:
                raise RPCError(-32601, "Method not found: {}".format(method))
            if req_id is not None:
                self._send({"jsonrpc": "2.0", "id": req_id, "result": {} if result is None else result})
        except RPCError as exc:
            if req_id is not None:
                self._send({"jsonrpc": "2.0", "id": req_id, "error": {"code": exc.code, "message": exc.message}})
        except Exception as exc:
            sys.stderr.write(traceback.format_exc())
            sys.stderr.flush()
            if req_id is not None:
                self._send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32000, "message": str(exc)}})

    def run(self):
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception as exc:
                sys.stderr.write("Invalid JSON-RPC message: {}\n".format(exc))
                sys.stderr.flush()
                continue
            if not isinstance(msg, dict):
                continue
            if "method" not in msg and "id" in msg:
                with self._pending_lock:
                    entry = self._pending.pop(msg["id"], None)
                if entry is not None:
                    event, holder = entry
                    if "error" in msg:
                        holder["error"] = msg["error"]
                    else:
                        holder["result"] = msg.get("result")
                    event.set()
                continue
            method = msg.get("method")
            if method == "shutdown":
                self._shutdown.set()
                break
            if method == "$/cancelRequest":
                cancel_id = (msg.get("params") or {}).get("id")
                if cancel_id is not None:
                    self._cancelled.add(cancel_id)
                continue
            worker = threading.Thread(target=self._handle_incoming, args=(msg,), daemon=True)
            worker.start()
