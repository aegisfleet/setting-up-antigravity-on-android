#!/opt/embedding-env/bin/python3
"""
EmbeddingGemma 2 Integration Service for T3 Code & Android PRoot
Provides:
  1. CLI semantic search: `t3-search <query> [path]`
  2. MCP server (JSON-RPC stdio): `t3-embed-mcp`
  3. OpenAI-compatible /v1/embeddings HTTP server: `t3-embed-server --port 8000`
"""
import sys
import os
import json
import time
import argparse
import signal
from pathlib import Path

# Prevent PRoot terminal control suspension
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
signal.signal(signal.SIGTTIN, signal.SIG_IGN)
signal.signal(signal.SIGTSTP, signal.SIG_IGN)

MODEL_NAME = "google/embeddinggemma-2"
_model_instance = None

def get_model():
    global _model_instance
    if _model_instance is None:
        import torch
        from sentence_transformers import SentenceTransformer
        # Load local snapshot if available, else load from HF cache/hub
        _model_instance = SentenceTransformer(
            MODEL_NAME,
            device="cpu",
            model_kwargs={"torch_dtype": torch.bfloat16}
        )
    return _model_instance

def compute_embeddings(texts):
    import torch
    model = get_model()
    with torch.no_grad():
        embs = model.encode(texts, convert_to_tensor=True, show_progress_bar=False)
    return embs

def semantic_search(query, target_dir=".", top_k=5, max_files=100):
    import torch
    from sentence_transformers import util

    target_path = Path(target_dir).resolve()
    if not target_path.exists():
        return [{"error": f"Path not found: {target_dir}"}]

    # Collect files
    supported_exts = {".py", ".js", ".ts", ".jsx", ".tsx", ".sh", ".md", ".json", ".html", ".css", ".rs", ".go", ".c", ".cpp", ".h", ".java", ".kt"}
    ignore_dirs = {".git", "node_modules", ".t3", "build", "dist", ".cache", "__pycache__", "venv", ".venv"}

    file_chunks = []
    chunk_meta = []

    count = 0
    for root, dirs, files in os.walk(target_path):
        dirs[:] = [d for d in dirs if d not in ignore_dirs and not d.startswith(".")]
        for file in files:
            p = Path(root) / file
            if p.suffix.lower() in supported_exts:
                try:
                    if p.stat().st_size > 100 * 1024:  # Skip files > 100KB
                        continue
                    text = p.read_text(encoding="utf-8", errors="ignore").strip()
                    if not text:
                        continue
                    
                    # Split into sections/chunks of ~500 chars
                    lines = text.splitlines()
                    for idx in range(0, len(lines), 30):
                        chunk = "\n".join(lines[idx:idx+30]).strip()
                        if len(chunk) > 30:
                            file_chunks.append(chunk)
                            rel_path = str(p.relative_to(target_path))
                            chunk_meta.append({
                                "file": rel_path,
                                "start_line": idx + 1,
                                "end_line": min(idx + 30, len(lines)),
                                "snippet": chunk[:200]
                            })
                    count += 1
                    if count >= max_files:
                        break
                except Exception:
                    pass
        if count >= max_files:
            break

    if not file_chunks:
        return []

    model = get_model()
    with torch.no_grad():
        q_emb = model.encode(query, convert_to_tensor=True, show_progress_bar=False)
        doc_embs = model.encode(file_chunks, convert_to_tensor=True, show_progress_bar=False)
        scores = util.cos_sim(q_emb, doc_embs)[0]

    top_results = []
    top_indices = torch.topk(scores, k=min(top_k, len(file_chunks))).indices.tolist()

    seen_files = set()
    for idx in top_indices:
        meta = chunk_meta[idx]
        score = float(scores[idx].item())
        meta_copy = dict(meta)
        meta_copy["score"] = round(score, 4)
        top_results.append(meta_copy)

    return top_results

# ----------------- MCP Server Mode -----------------
def run_mcp_server():
    """Simple stdio JSON-RPC MCP server for Claude / Antigravity / T3 Code."""
    sys.stderr.write("[EmbeddingGemma-MCP] Server initialized on stdio\n")
    sys.stderr.flush()

    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue

        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params", {})

        if method == "initialize":
            res = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "serverInfo": {
                        "name": "embeddinggemma-2-mcp",
                        "version": "1.0.0"
                    },
                    "capabilities": {
                        "tools": {}
                    }
                }
            }
        elif method == "tools/list":
            res = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "tools": [
                        {
                            "name": "semantic_code_search",
                            "description": "Search code and documents semantically using Google EmbeddingGemma 2 (multimodal embedding model on-device).",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "query": {
                                        "type": "string",
                                        "description": "Search query or natural language description of what you are looking for"
                                    },
                                    "path": {
                                        "type": "string",
                                        "description": "Target directory to search in (default: current workspace)",
                                        "default": "."
                                    },
                                    "top_k": {
                                        "type": "integer",
                                        "description": "Number of top matching code chunks to return",
                                        "default": 5
                                    }
                                },
                                "required": ["query"]
                            }
                        },
                        {
                            "name": "get_embeddings",
                            "description": "Generate 768-dimensional vector embeddings for a list of texts using EmbeddingGemma 2.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "texts": {
                                        "type": "array",
                                        "items": {"type": "string"},
                                        "description": "Array of strings to encode"
                                    }
                                },
                                "required": ["texts"]
                            }
                        }
                    ]
                }
            }
        elif method == "tools/call":
            tool_name = params.get("name")
            args = params.get("arguments", {})

            if tool_name == "semantic_code_search":
                q = args.get("query", "")
                target_p = args.get("path", ".")
                k = args.get("top_k", 5)
                results = semantic_search(q, target_dir=target_p, top_k=k)
                content_text = json.dumps(results, indent=2, ensure_ascii=False)
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [
                            {"type": "text", "text": content_text}
                        ]
                    }
                }
            elif tool_name == "get_embeddings":
                texts = args.get("texts", [])
                embs = compute_embeddings(texts).tolist()
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [
                            {"type": "text", "text": json.dumps({"count": len(embs), "dim": 768, "embeddings": embs})}
                        ]
                    }
                }
            else:
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"Method not found: {tool_name}"}
                }
        else:
            res = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {}
            }

        sys.stdout.write(json.dumps(res) + "\n")
        sys.stdout.flush()

# ----------------- HTTP Server Mode (/v1/embeddings) -----------------
def run_http_server(host="0.0.0.0", port=8000):
    from http.server import HTTPServer, BaseHTTPRequestHandler

    class EmbeddingHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path in ("/v1/embeddings", "/embeddings"):
                content_len = int(self.headers.get("Content-Length", 0))
                post_body = self.rfile.read(content_len)
                try:
                    data = json.loads(post_body.decode())
                    inp = data.get("input", "")
                    if isinstance(inp, str):
                        inputs = [inp]
                    else:
                        inputs = list(inp)

                    embs = compute_embeddings(inputs).tolist()
                    resp_data = {
                        "object": "list",
                        "data": [
                            {
                                "object": "embedding",
                                "embedding": emb,
                                "index": i
                            } for i, emb in enumerate(embs)
                        ],
                        "model": MODEL_NAME,
                        "usage": {
                            "prompt_tokens": len(inputs) * 10,
                            "total_tokens": len(inputs) * 10
                        }
                    }
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps(resp_data).encode())
                except Exception as e:
                    self.send_response(500)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps({"error": str(e)}).encode())
            else:
                self.send_response(404)
                self.end_headers()

        def do_GET(self):
            if self.path == "/health":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"status": "ok", "model": MODEL_NAME}).encode())
            else:
                self.send_response(404)
                self.end_headers()

    server = HTTPServer((host, port), EmbeddingHandler)
    print(f"EmbeddingGemma 2 OpenAI-compatible API running on http://{host}:{port}/v1/embeddings")
    server.serve_forever()

# ----------------- CLI Mode -----------------
def main():
    parser = argparse.ArgumentParser(description="EmbeddingGemma 2 Service for T3 Code & Android")
    parser.add_argument("query", nargs="?", help="Search query for semantic search")
    parser.add_argument("--path", "-p", default=".", help="Target path to search in (default: .)")
    parser.add_argument("--top-k", "-k", type=int, default=5, help="Number of results (default: 5)")
    parser.add_argument("--mcp", action="store_true", help="Run as stdio MCP server")
    parser.add_argument("--serve", action="store_true", help="Run as HTTP API server (/v1/embeddings)")
    parser.add_argument("--port", type=int, default=8000, help="HTTP server port (default: 8000)")
    parser.add_argument("--host", default="127.0.0.1", help="HTTP server host (default: 127.0.0.1)")

    args = parser.parse_args()

    if args.mcp:
        run_mcp_server()
    elif args.serve:
        run_http_server(host=args.host, port=args.port)
    elif args.query:
        print(f"🔍 Searching semantically for: \"{args.query}\" in {os.path.abspath(args.path)}...")
        t0 = time.time()
        results = semantic_search(args.query, target_dir=args.path, top_k=args.top_k)
        elapsed = time.time() - t0
        print(f"Done in {elapsed:.2f}s! Top {len(results)} matches:\n")
        for i, res in enumerate(results, 1):
            score = res.get("score", 0.0)
            fpath = res.get("file", "")
            sline = res.get("start_line", 1)
            eline = res.get("end_line", 1)
            snippet = res.get("snippet", "").replace("\n", " ")[:120]
            print(f"[{i}] Score: {score:.4f} | {fpath}:{sline}-{eline}")
            print(f"    Snippet: {snippet}...\n")
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
