import json
import os
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

def _log(msg: str) -> None:
    try:
        print(msg, flush=True)
    except Exception:
        pass

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Keep default access logs, but make sure they flush.
        _log("%s - - [%s] %s" % (self.address_string(), self.log_date_time_string(), format % args))

    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/mkdir':
            try:
                length = int(self.headers.get('Content-Length', 0))
                data = json.loads(self.rfile.read(length))
                p = (data.get('path', '') or '').strip()
                if not p:
                    self.send_response(400)
                    self.end_headers()
                    return

                # Safety: only allow creating dirs inside backup dir.
                base = os.path.realpath(os.environ.get('BACKUP_DIR', '/var/lib/chirpstack/backups'))
                target = os.path.realpath(p)
                if target == base or not target.startswith(base + os.sep):
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(b'forbidden')
                    return

                os.makedirs(target, exist_ok=True)

                # Best-effort: relax permissions so other containers/users can write.
                # Walk from base -> target, chmod each component.
                rel = os.path.relpath(target, base)
                cur = base
                try:
                    os.chmod(cur, 0o777)
                except Exception:
                    pass
                for part in rel.split(os.sep):
                    cur = os.path.join(cur, part)
                    try:
                        os.chmod(cur, 0o777)
                    except Exception:
                        pass

                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ok')
                return
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode())
                return

        if self.path == '/delete':
            try:
                length = int(self.headers.get('Content-Length', 0))
                data = json.loads(self.rfile.read(length))
                p = (data.get('path', '') or '').strip()
                if not p:
                    self.send_response(400)
                    self.end_headers()
                    return

                # Best-effort safety: only allow deletes inside backup dir.
                base = os.path.realpath(os.environ.get('BACKUP_DIR', '/var/lib/chirpstack/backups'))
                target = os.path.realpath(p)
                if not target.startswith(base + os.sep):
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(b'forbidden')
                    return

                try:
                    os.remove(target)
                except FileNotFoundError:
                    pass

                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ok')
                return
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode())
                return

        if self.path == '/pg_restore':
            try:
                length = int(self.headers.get('Content-Length', 0))
                data = json.loads(self.rfile.read(length))

                dsn = data.get('dsn', '').strip()
                dump_path = data.get('dumpPath', '').strip()

                if not dsn or not dump_path:
                    self.send_response(400)
                    self.end_headers()
                    return

                cmd = [
                    'pg_restore',
                    '--clean',
                    '--if-exists',
                    '--no-owner',
                    '--no-acl',
                    '--dbname',
                    dsn,
                    dump_path,
                ]
                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    msg = (result.stderr or result.stdout or '').strip() or 'pg_restore failed'
                    _log(f"RUNNER /pg_restore failed (rc={result.returncode}) cmd={cmd} err={msg}")
                    raise RuntimeError(msg)

                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ok')
                return
            except Exception as e:
                _log(f"RUNNER /pg_restore exception: {e}")
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode())
                return

        if self.path != '/pg_dump':
            self.send_response(404)
            self.end_headers()
            return

        try:
            length = int(self.headers.get('Content-Length', 0))
            data = json.loads(self.rfile.read(length))

            dsn = data.get('dsn', '').strip()
            out_path = data.get('outPath', '').strip()
            fmt = data.get('format', 'custom')
            append = bool(data.get('append', False))
            header = data.get('header', '')

            if not dsn or not out_path:
                self.send_response(400)
                self.end_headers()
                return

            os.makedirs(os.path.dirname(out_path) or '.', exist_ok=True)

            # 执行pg_dump
            # - custom format: write directly to file (cannot append safely)
            # - plain format: stream stdout to file, supports append
            if fmt == 'plain':
                mode = 'a' if append else 'w'
                with open(out_path, mode, encoding='utf-8') as f:
                    if header:
                        f.write(header)
                    cmd = ['pg_dump', '--format=plain', '--dbname', dsn]
                    proc = subprocess.Popen(cmd, stdout=f, stderr=subprocess.PIPE, text=True)
                    _, err = proc.communicate()
                    if proc.returncode != 0:
                        raise RuntimeError(err.strip() if err else 'pg_dump failed')
            else:
                # default: custom format (overwrite)
                cmd = ['pg_dump', f'--format={fmt}', '--file', out_path, '--dbname', dsn]
                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    msg = (result.stderr or result.stdout or '').strip() or 'pg_dump failed'
                    _log(f"RUNNER /pg_dump failed (rc={result.returncode}) cmd={cmd} err={msg}")
                    raise RuntimeError(msg)

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'ok')

        except Exception as e:
            _log(f"RUNNER /pg_dump exception: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

if __name__ == '__main__':
    port = int(os.environ.get('RUNNER_PORT', 8081))
    _log(f'Starting backup runner on 0.0.0.0:{port}')
    HTTPServer(('0.0.0.0', port), Handler).serve_forever()
