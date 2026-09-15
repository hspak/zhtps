"""Compile the recorded benchmark reports into one offline HTML document.

Requires Python-Markdown at build time; the generated document has no external
assets or runtime dependencies. Retained reports and run summaries are embedded
once and available as downloads. Source links require the repository checkout.
"""

import argparse
import base64
import gzip
import hashlib
from functools import lru_cache
from html import escape
from html.parser import HTMLParser
import json
import mimetypes
import os
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

import markdown

ROOT = Path(__file__).resolve().parents[1]
REPORTS = [
    ("overload", "docs/overload.md", "Sustained overload validation"),
    ("native-admission", "docs/native-admission.md", "Direct-server admission and measurements"),
    ("ingress", "docs/ingress.md", "Ingress policy and local validation"),
    ("current-go", "docs/go-comparison-current.md", "September 12 Go comparison rerun"),
    ("multicore", "docs/go-comparison-workers.md", "16-worker Go comparison"),
    ("overflow", "docs/go-comparison-8192-overflow.md", "8,192-client connection overflow"),
    ("high-connections", "docs/go-comparison-high-connections.md", "Higher-connection comparison"),
    ("original", "docs/go-comparison.md", "Original Go comparison"),
    ("workers", "docs/workers.md", "Worker implementation and calibration"),
]
GROUPS = [
    ("http2", "HTTP/2: remote LAN and loopback", [
        ("http2-lan", "http2-lan", "HTTP/2 over the LAN: 64 to 16,384 connections and every failure"),
        ("http2-diagnosis", "http2-diagnosis", "ZHTPS HTTP/2 failures: NIC receive loss and paired TCP evidence"),
        ("bun-http2-review", "bun-http2-review", "Bun HTTP/2 source review: strategies for ZHTPS multi-worker performance"),
        ("bun-http2-implementation", "bun-http2-implementation", "Three Bun-inspired HTTP/2 candidates: measured retain/revert decisions"),
        ("http2-comparison", "http2-comparison", "Earlier HTTP/2 loopback: ZHTPS, Go, Node and Bun"),
    ]),
    ("final", "Final decisions", [
        ("wrap-up", "go-performance-wrap-up", "Investigation wrap-up"),
        ("retained-retries", "tcp-read-timeout-mitigation", "Retained TCP retries: final 48-run comparison"),
    ]),
    ("architecture", "Architecture and nginx", [
        ("architecture-review", "architecture-review", "Go source review: ten ranked architectural decisions"),
        ("architecture-implementation", "architecture-implementation", "Architecture changes: implementation and rejected alternatives"),
        ("nginx-review", "nginx-review", "nginx source review: compatible performance strategies"),
        ("nginx-implementation", "nginx-implementation", "Three nginx-inspired changes: storage, reclamation, streaming"),
        ("keepalive-policy", "keepalive-policy", "Keepalive defaults: returning clients and shutdown races"),
        ("nic-placement", "nic-placement", "NIC-aware worker placement"),
    ]),
    ("lan", "Go comparisons over the LAN", [
        ("lan-go", "go-comparison-lan", "Second-host LAN comparison: one CPU and sixteen workers"),
        ("lan-workers32", "go-comparison-lan-workers32", "32 workers at 8k and 16k connections"),
        ("go-after-nginx", "go-after-nginx", "Go comparison after the nginx-inspired changes"),
    ]),
    ("uploads", "Uploads, memory and generator", [
        ("upload-parity", "upload-parity", "Upload attribution: CRC32, queue collisions and buffer churn"),
        ("go-followup", "go-performance-followup", "Connection buffers, client memory and remaining Go comparisons"),
        ("thin-retry-upload", "thin-retry-upload", "Three-way uploads with the retry prototype"),
    ]),
    ("delivery", "Timeout investigations", [
        ("timeout-mitigations", "read-timeout-mitigations", "Initial timeout investigation and thin-retry prototype"),
        ("thin-go", "read-timeout-thin-go", "Applying thin retries to Go: mechanism control"),
        ("rto50", "read-timeout-rto50", "Discarded: standalone 50 ms minimum RTO"),
        ("socket-info", "read-timeout-socket-info", "Client TCP_INFO: residual response stalls"),
        ("socket-correlation", "server-timeout-correlation", "Paired client/server socket correlation"),
        ("fixed-pacing", "send-pacing", "Discarded: fixed response pacing and longer confirmation"),
        ("napi", "napi-polling", "Discarded: server NAPI busy polling"),
        ("delivery-followup", "read-timeout-followup", "Driver transmit timestamps and limits of loss attribution"),
        ("adaptive-pacing", "adaptive-send-pacing", "Discarded: adaptive pacing, request backlog and NIC findings"),
    ]),
    ("early", "Earlier performance experiments", [
        ("request-critical-path", "request-critical-path", "Request critical path: review and cost budget"),
        ("critical-path", "critical-path-experiments", "Parser, clocks, logging and syscall experiments"),
        ("remaining-path", "request-path-remaining", "Remaining request path: bodies, streams, pipelines and churn"),
        ("request-footprint", "request-footprint", "Request footprint and cache layout"),
        ("response-v2", "response-aggregation-v2", "Response aggregation revisit"),
        ("response-integrated", "response-aggregation-integrated", "Response aggregation in the main server"),
        ("kernel-work", "kernel-work", "Kernel I/O, multishot and accept experiments"),
        ("simd", "simd", "SIMD and admission measurements"),
    ]),
    ("original", "Original report and loopback history", [
        (name, Path(path).stem, title) for name, path, title in REPORTS
    ]),
    ("verification", "Correctness and deployment context", [
        ("implementation", "implementation", "Implementation and verification"),
        ("conformance", "conformance", "HTTP conformance and regression history"),
        ("http-review", "http-rfc-review", "HTTP RFC source review"),
        ("security", "security", "Security review and operational boundaries"),
    ]),
]
# Keep original report anchors stable while rendering the historical reports.
REPORTS = [(name, f"docs/{stem}.md", title)
           for _, _, entries in GROUPS for name, stem, title in entries]
SUPPLEMENTS = [
    ("note-" + "-".join(path.relative_to(ROOT / "docs").with_suffix("").parts),
     str(path.relative_to(ROOT)),
     " / ".join(path.relative_to(ROOT / "docs").with_suffix("").parts))
    for path in sorted((ROOT / "docs").rglob("*.md"))
    if path.parent != ROOT / "docs" and not any(part.startswith("before") for part in path.parts)
]
REPORTS += SUPPLEMENTS
OVERVIEW = ("conclusions", "docs/performance-summary.md", "What the investigation established")


class Compiler:
    def __init__(self, output):
        self.output = output.resolve()
        self.documents = {(ROOT / path).resolve(): name for name, path, _ in [OVERVIEW, *REPORTS]}
        self.attachments = {}
        self.payloads = {}

    def source_key(self, path):
        path = path.resolve()
        if not (path.is_relative_to(ROOT) or path.is_relative_to(ROOT.parent / "nginx")):
            raise ValueError(f"source outside the reviewed repositories: {path}")
        return Path(os.path.relpath(path, ROOT)).as_posix()

    def attachment(self, path):
        path = path.resolve()
        if not self.retained_document(path):
            raise ValueError(f"not a retained report or summary: {path}")
        key = self.source_key(path)
        if key not in self.attachments:
            raw = path.read_bytes()
            digest = hashlib.sha256(raw).hexdigest()
            if digest not in self.payloads:
                compressed = gzip.compress(raw, compresslevel=6, mtime=0)
                use_gzip = len(compressed) + 64 < len(raw)
                self.payloads[digest] = {
                    "encoding": "gzip" if use_gzip else "identity",
                    "base64": base64.b64encode(compressed if use_gzip else raw).decode("ascii"),
                }
            self.attachments[key] = {
                "name": path.name,
                "bytes": len(raw),
                "sha256": digest,
            }
        return key

    @staticmethod
    def retained_document(path):
        return path.is_relative_to(ROOT / 'docs') and (
            path.suffix in {'.md', '.csv', '.svg'}
            or path.parent == ROOT / 'docs/runs' and path.suffix == '.json'
        )

    def directory(self, path):
        for child in sorted(path.rglob("*")):
            if child.is_file() and self.retained_document(child):
                self.attachment(child)
        return self.source_key(path) + "/"

    def render(self, name, path):
        renderer = markdown.Markdown(extensions=["tables", "fenced_code", "toc"])
        html = renderer.convert(path.read_text())
        rewrite = ReportHtml(self, name, path)
        rewrite.feed(html)
        rewrite.close()
        sections = renderer.toc_tokens[0].get("children", []) if renderer.toc_tokens else []
        navigation = "".join(
            f'<a href="#{name}--{escape(item["id"], quote=True)}">{escape(item["name"])}</a>'
            for item in sections
        )
        return "".join(rewrite.parts), navigation


class ReportHtml(HTMLParser):
    def __init__(self, compiler, name, path):
        super().__init__(convert_charrefs=False)
        self.compiler, self.name, self.path = compiler, name, path
        self.parts = []

    def handle_startendtag(self, tag, attributes):
        self.handle_starttag(tag, attributes)
        if tag not in ("img", "br", "hr", "input", "meta", "link"):
            self.handle_endtag(tag)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if "id" in attrs:
            attrs["id"] = f'{self.name}--{attrs["id"]}'
        if tag == "a" and "href" in attrs:
            url = urlsplit(attrs["href"])
            if not url.scheme and not url.netloc:
                target = (self.path.parent / unquote(url.path)).resolve() if url.path else self.path
                line = None
                match = re.search(r":(\d+)$", target.name)
                if match:
                    line = match[1]
                    target = target.with_name(target.name[:match.start()])
                if target == ROOT / 'docs/benchmarks.html' or target == self.compiler.output:
                    attrs["href"] = "#top"
                elif target in self.compiler.documents:
                    anchor = self.compiler.documents[target]
                    attrs["href"] = f'#{anchor}--{url.fragment}' if url.fragment else f"#{anchor}"
                elif target.is_dir() and target.is_relative_to(ROOT / 'docs'):
                    prefix = self.compiler.directory(target)
                    attrs.update(href="#sources", **{"data-source-prefix": prefix})
                    attrs["title"] = f"Browse embedded files in {prefix}"
                elif self.compiler.retained_document(target):
                    key = self.compiler.attachment(target)
                    attrs.update(href="#sources", **{"data-download": key})
                    attrs["title"] = f"Download embedded {target.name}" + (f"; cited line {line}" if line else "")
                else:
                    if target.is_relative_to(ROOT / 'docs'):
                        raise ValueError(f'link to unretained artifact: {target}')
                    attrs['href'] = os.path.relpath(target, self.compiler.output.parent)
                    if url.fragment:
                        attrs['href'] += '#' + url.fragment
                    attrs['title'] = 'Source reference; requires the repository checkout'
                    if line:
                        attrs['title'] += f'; cited line {line}'
        if tag == "img":
            target = (self.path.parent / attrs["src"]).resolve()
            encoded = base64.b64encode(target.read_bytes()).decode("ascii")
            mime = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
            attrs["src"] = f"data:{mime};base64,{encoded}"
            attrs["loading"] = "lazy"
        if tag == "table":
            self.parts.append('<div class="table-scroll" tabindex="0" role="region" aria-label="Measurement table">')
        if tag in ("h1", "h2", "h3", "h4", "h5"):
            tag = f"h{int(tag[1]) + 1}"
        rendered = "".join(f' {key}="{escape(value, quote=True)}"' if value is not None else f" {key}"
                           for key, value in attrs.items())
        self.parts.append(f"<{tag}{rendered}>")

    def handle_endtag(self, tag):
        original = tag
        if tag in ("h1", "h2", "h3", "h4", "h5"):
            tag = f"h{int(tag[1]) + 1}"
        self.parts.append(f"</{tag}>")
        if original == "table":
            self.parts.append("</div>")

    def handle_data(self, text):
        self.parts.append(text)

    def handle_entityref(self, name):
        self.parts.append(f"&{name};")

    def handle_charref(self, name):
        self.parts.append(f"&#{name};")


@lru_cache(maxsize=None)
def recorded_catalog(group):
    return json.loads((ROOT / 'docs/runs' / (group + '.json')).read_text())


def recorded_result(original_path):
    """Read a summary by its historical artifact path, not a live filesystem path."""
    parts = Path(original_path).parts
    group = parts[1] if len(parts) > 2 else 'standalone'
    catalog = recorded_catalog(group)
    if catalog['schema_version'] != 1:
        raise ValueError(f'unsupported run catalog schema: {group}')
    return catalog['records'][original_path]['record']


def experiments():
    # CPU intervals and phases were summarized before raw samples were retired.
    return json.loads((ROOT / 'docs/runs/overload-phases.json').read_text())


def embedded_json(value):
    # Script elements terminate on literal </script>, even for application/json.
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True).replace("<", "\\u003c")


STATUS_LABELS = {
    "observed_lead_with_separated_trial_ranges": "Favorable · separated ranges",
    "observed_lower_total": "Lower count total",
    "open_overlapping_trials": "Favorable median · overlap / open",
    "open_tie": "Tie · open",
    "open_worse": "Unfavorable · open",
    "accepted_tradeoff": "Accepted p50 tradeoff",
}
METRICS = {
    "goodput": ("Validated responses/s", "/s"),
    "goodput_mib_per_second": ("Validated upload MiB/s", "MiB/s"),
    "p50_ms": ("Successful-exchange p50", "ms"),
    "p99_ms": ("Successful-exchange p99", "ms"),
    "cpu_us": ("Process CPU / valid response", "µs"),
    "cpu_us_per_mib": ("Process CPU / uploaded MiB", "µs/MiB"),
    "rss_mib": ("Sampled server RSS", "MiB"),
    "read_timeouts": ("Read timeouts", "count"),
    "failures": ("All HTTP failures", "count"),
    "generator_drops": ("Generator drops + expirations", "count"),
    "setup_errors": ("Setup errors", "count"),
    "warmup_errors": ("Warmup errors", "count"),
}


def workload_label(row):
    if row["workload_kind"] == "get":
        connections = "8k" if row["group"].endswith("8192") else "16k"
        load = f'{row["rate"] // 1000}k offered/s' if row["rate"] else "saturated"
        return f"GET · {connections} · {load}"
    return {
        "integrated-upload-small": "Upload · 64 KiB · default queues",
        "integrated-upload-calibrated-small": "Upload · 64 KiB · distinct queues",
        "integrated-upload-large": "Upload · 8 MiB · distinct queues",
        "integrated-upload-paced": "Upload · 8 MiB · 200 MiB/s cap",
    }[row["group"]]


def display_number(value):
    if value is None:
        return "—"
    return f"{value:,.6f}".rstrip("0").rstrip(".") if isinstance(value, float) else f"{value:,}"


def current_results():
    ledger = recorded_result("docs/thin-retry-integration/comparisons.json")
    acceptance = recorded_result("docs/thin-retry-integration/acceptance.json")
    accepted = {(r["group"], r["rate"], r["metric"]) for r in acceptance["accepted_comparisons"]}
    rows = []
    chart = []
    for row in ledger["comparisons"]:
        status = ("accepted_tradeoff" if (row["group"], row.get("rate"), row["metric"]) in accepted
                  else row["status"])
        label, unit = METRICS[row["metric"]]
        cells = []
        for side in ("candidate", "reference"):
            value = row.get(f"{side}_median", row.get(f"{side}_total"))
            cell = display_number(value)
            trials = row.get(f"{side}_trials")
            if trials:
                cell += (f'<details class="trial-values"><summary>3 trials</summary>'
                         + ", ".join(display_number(v) for v in trials) + "</details>")
            cells.append(f"<td>{cell}</td>")
        change = row.get("percent_change")
        delta = f"{change:+.4f}%" if change is not None else "—"
        rows.append(
            f'<tr data-kind="{row["workload_kind"]}" data-status="{status}">'
            f'<th scope="row">{escape(workload_label(row))}</th><td>{escape(label)}<small>{unit}</small></td>'
            + "".join(cells) + f'<td>{delta}</td><td><span class="status {status}">'
            f'{STATUS_LABELS[status]}</span></td></tr>'
        )
    for group, rate in [
        ("integrated-go-offered-8192", 300000),
        ("integrated-go-saturated-8192", 0),
        ("integrated-go-offered-16384", 300000),
        ("integrated-go-saturated-16384", 0),
    ]:
        measured = [r for r in ledger["comparisons"] if r["group"] == group and r.get("rate") == rate]
        chart.append({"label": workload_label(measured[0]), "metrics": {
            r["metric"]: {"zhtps": r.get("candidate_median", r.get("candidate_total")),
                          "go": r.get("reference_median", r.get("reference_total"))}
            for r in measured
        }})
    overview_rows = []
    for item in chart:
        metrics = item["metrics"]
        values = [escape(item["label"])]
        for metric in ("goodput", "p50_ms", "p99_ms", "read_timeouts"):
            values.append(" / ".join(
                f'{metrics[metric][side]:,.3f}'.rstrip("0").rstrip(".")
                if metric in ("p50_ms", "p99_ms") else f'{metrics[metric][side]:,.0f}'
                for side in ("zhtps", "go")
            ))
        overview_rows.append("<tr>" + "".join(f"<td>{v}</td>" for v in values) + "</tr>")
    return "".join(rows), "".join(overview_rows), chart


def http2_results():
    report = recorded_result("docs/http2-comparison/results.json")
    if not report["complete"]:
        raise ValueError("HTTP/2 comparison is incomplete")
    measured = {(row["workers"], row["connections"], row["streams"], row["server"]): row
                for row in report["medians"]}
    single, multi = [], []

    def cell(row):
        return (f'<td>{row["requests_per_second"]:,.0f}'
                f'<small>p99 {row["p99_ms"]:.3f} ms</small></td>')

    for connections, streams in ((1, 1), (1, 32), (8, 32), (64, 4)):
        single.append(f'<tr><th scope="row">{connections} × {streams}</th>' + "".join(
            cell(measured[1, connections, streams, name]) for name in ("zhtps", "go", "node", "bun")
        ) + "</tr>")
    for workers in (2, 4, 8):
        for connections, streams in ((8, 32), (64, 4)):
            zhtps = measured[workers, connections, streams, "zhtps"]
            go = measured[workers, connections, streams, "go"]
            multi.append(
                f'<tr><th scope="row">{workers}</th><td>{connections} × {streams}</td>'
                + cell(zhtps) + cell(go)
                + f'<td>{zhtps["requests_per_second"] / go["requests_per_second"]:.2f}×</td></tr>'
            )
    return "".join(single), "".join(multi), report["medians"]


def http2_lan_results():
    report = recorded_result("docs/http2-lan/summary.json")
    if not report['audit']['passed']:
        raise ValueError('HTTP/2 LAN audit did not pass')
    rows = report['rows']
    measured = {(r['workers'], r['connections'], r['server']): r for r in rows}
    names = {'zhtps': 'ZHTPS', 'go': 'Go', 'node': 'Node', 'bun': 'Bun'}

    def extent(row, key):
        low, high = row['min_' + key], row['max_' + key]
        return f'{low:,}' if low == high else f'{low:,}–{high:,}'

    def cell(row):
        partial = row['full_population_trials'] != row['trials']
        mark = ' †' if partial else ''
        population = (f"<small>Ready {extent(row, 'ready_connections')} / {row['connections']:,}</small>"
                      if partial else '')
        p99 = '—' if row['p99_ms'] is None else f'{row["p99_ms"]:.3f} ms'
        return (f'<td>{row["requests_per_second"]:,.0f}{mark}'
                f'<small>p99 {p99}</small>'
                f'<small>{row["measurement_failed"]:,} measured failures</small>{population}</td>')

    single, multi, failures, totals = [], [], [], []
    for connections in (64, 1024, 8192, 16384):
        single.append(f'<tr><th scope="row">{connections:,} × 4</th>' + ''.join(
            cell(measured[1, connections, server]) for server in names) + '</tr>')
    for workers in (2, 4, 8):
        for connections in (64, 1024, 8192, 16384):
            multi.append(f'<tr><th scope="row">{workers}</th><td>{connections:,} × 4</td>' + ''.join(
                cell(measured[workers, connections, server]) for server in ('zhtps', 'go')) + '</tr>')
    for row in rows:
        failures.append(f'<tr><td>{row["workers"]}</td><td>{row["connections"]:,}</td>'
                        f'<th scope="row">{names[row["server"]]}</th>'
                        f'<td>{extent(row, "ready_connections")}</td>'
                        + ''.join(f'<td>{row[phase + "_failed"]:,}</td>' for phase in
                                  ('setup', 'holding', 'warmup', 'measurement'))
                        + f'<td>{row["setup_unattempted"]:,}</td></tr>')
    for row in report['totals']:
        totals.append(f'<tr><th scope="row">{names[row["server"]]}</th><td>{row["trials"]}</td>'
                      + ''.join(f'<td>{row[key]:,}</td>' for key in
                                ('setup_failed', 'holding_failed', 'warmup_failed', 'measurement_failed')) + '</tr>')
    stats = (f'{report["audit"]["trials"]} audited remote trials · '
             f'{report["audit"]["measured_successes"]:,} verified measured responses · '
             f'{sum(r["measurement_failed"] for r in report["totals"]):,} measured failures')
    return ''.join(single), ''.join(multi), ''.join(failures), ''.join(totals), stats, rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/benchmarks.html")
    options = parser.parse_args()
    compiler = Compiler(options.output)
    document, navigation = compiler.render(OVERVIEW[0], ROOT / OVERVIEW[1])
    archives, archive_navigation = [], []
    rendered = {}
    for name, path, title in REPORTS:
        content, _ = compiler.render(name, ROOT / path)
        rendered[name] = (title, content)
    grouped = [(key, title, [name for name, _, _ in entries]) for key, title, entries in GROUPS]
    grouped.append(("notes", "Design notes, setup controls and supplementary tables", [r[0] for r in SUPPLEMENTS]))
    for key, title, names in grouped:
        archives.append(f'<div class="report-group" id="group-{key}"><h3>{escape(title)}</h3>')
        archive_navigation.append(f'<a href="#group-{key}">{escape(title)}</a>')
        for name in names:
            report_title, content = rendered[name]
            historical = ("Current wrap-up; preference updated after the investigation stopped."
                          if name == "wrap-up" else
                          "September 14 HTTP/2 measurements: local loopback clients on separate physical cores. "
                          "The remote load host was not used."
                          if name == "http2-comparison" else
                          "September 14 HTTP/2 LAN measurements: separate load host client.example, "
                          "four streams per connection, with all failures retained."
                          if name == "http2-lan" else
                          "September 14 follow-up: 18 separate ZHTPS diagnostic trials. "
                          "The original comparison is preserved."
                          if name == "http2-diagnosis" else
                          "September 14 source review: ranked opportunities for ZHTPS multi-worker performance. "
                          "No production changes or new benchmark results."
                          if name == "bun-http2-review" else
                          "Sequential optimization experiments. Retain/revert decisions are separate from the original runtime comparison."
                          if name == "bun-http2-implementation" else
                          "Historical report. Read the final conclusions for current acceptance and decisions; "
                          "historical next steps are not scheduled work.")
            archives.append(
                f'<details class="archive report-entry" id="{name}" data-group="{key}">'
                f'<summary>{escape(report_title)}</summary><div class="prose archive-body">'
                f'<p class="history-note">{historical}</p>{content}</div></details>'
            )
        archives.append("</div>")
    for _, path, _ in [OVERVIEW, *REPORTS]:
        compiler.attachment(ROOT / path)
    measurements = experiments()
    for path in sorted((ROOT / 'docs/runs').glob('*.json')):
        compiler.attachment(path)
    rows, overview_rows, chart = current_results()
    http2_single, http2_multi, http2_chart = http2_results()
    lan_single, lan_multi, lan_failures, lan_totals, lan_stats, lan_chart = http2_lan_results()
    lan_calibration = recorded_result('docs/http2-lan/calibration.json')
    downloads = "".join(
        f'<a href="#sources" data-download="{escape(key, quote=True)}" '
        f'title="{value["bytes"]:,} bytes · SHA-256 {value["sha256"]}">{escape(key)}</a>'
        for key, value in sorted(compiler.attachments.items())
    )
    replacements = {
        "@@NAVIGATION@@": navigation,
        "@@ARCHIVE_NAVIGATION@@": "".join(archive_navigation),
        "@@REPORT@@": document,
        "@@ARCHIVES@@": "".join(archives),
        "@@DOWNLOADS@@": downloads,
        "@@EXPERIMENTS@@": embedded_json(measurements),
        "@@ATTACHMENTS@@": embedded_json({"files": compiler.attachments, "payloads": compiler.payloads}),
        "@@COMPARISONS@@": rows,
        "@@CURRENT_ROWS@@": overview_rows,
        "@@CHART@@": embedded_json(chart),
        "@@HTTP2_SINGLE@@": http2_single,
        "@@HTTP2_MULTI@@": http2_multi,
        "@@HTTP2_CHART@@": embedded_json(http2_chart),
        "@@HTTP2_LAN_SINGLE@@": lan_single,
        "@@HTTP2_LAN_MULTI@@": lan_multi,
        "@@HTTP2_LAN_FAILURES@@": lan_failures,
        "@@HTTP2_LAN_TOTALS@@": lan_totals,
        "@@HTTP2_LAN_STATS@@": lan_stats,
        "@@HTTP2_LAN_CHART@@": embedded_json(lan_chart),
        "@@HTTP2_LAN_CALIBRATION@@": escape(lan_calibration['finding']),
        "@@SOURCE_COUNT@@": str(len(compiler.attachments)),
        "@@REPORT_COUNT@@": str(len(REPORTS) + 1),
        "@@APPENDIX_COUNT@@": str(len(REPORTS)),
    }
    html = (ROOT / "bench/report.html").read_text()
    html = html.replace('@@HTTP2_LAN_SECTION@@', (ROOT / 'bench/http2_lan_report.html').read_text())
    for marker, replacement in replacements.items():
        if marker not in html:
            raise ValueError(f"missing template marker: {marker}")
        html = html.replace(marker, replacement)
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(html)
    print(f"Wrote {options.output}: {len(html.encode()):,} bytes, {len(REPORTS) + 1} reports, "
          f"{len(compiler.attachments)} embedded reports and summaries")


if __name__ == "__main__":
    main()
