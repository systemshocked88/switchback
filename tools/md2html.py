"""Turn a simple Markdown document (the user guide, the reminder) into a standalone HTML page.

    python tools/md2html.py docs/guide.md docs/guide.html

Understands what these documents use: # / ## / ### headings, paragraphs, tables, numbered and bulleted lists
(with a nested bulleted list under an item), > quotes (shown as a warning box), `code`, **bold**, links, ---.
Each ## starts a card; the page gets a table of contents, light and dark themes and a phone-friendly layout.
"""
import html
import re
import sys

STYLE = """<style>
  :root { --bg:#f7f7f5; --card:#fff; --text:#1f2328; --muted:#5b636e; --line:#e2e4e8;
          --accent:#2f6fdb; --code-bg:#f0f2f5; --warn:#b4540a; --warn-bg:#fff4e5; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#15181c; --card:#1d2126; --text:#e6e8eb; --muted:#9aa3ad; --line:#2f353c;
            --accent:#7aa7ff; --code-bg:#262b31; --warn:#ffb366; --warn-bg:#3a2a17; }
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:16px/1.55 -apple-system, "Segoe UI", Roboto, Arial, sans-serif; }
  main { max-width:920px; margin:0 auto; padding:24px 16px 64px; }
  h1 { font-size:1.7rem; margin:0 0 6px; }
  .sub { color:var(--muted); margin:0 0 20px; }
  nav { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:12px 16px; margin-bottom:24px; }
  nav ol { margin:0; padding-left:20px; }
  nav a { color:var(--accent); text-decoration:none; }
  section { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:4px 20px 16px; margin-bottom:18px; }
  h2 { font-size:1.3rem; margin:18px 0 10px; }
  h3 { font-size:1.08rem; margin:20px 0 6px; }
  p, li { margin:6px 0; }
  ol, ul { padding-left:22px; }
  .table-wrap { overflow-x:auto; margin:10px 0; }
  table { border-collapse:collapse; width:100%; font-size:.95rem; }
  th, td { text-align:left; vertical-align:top; padding:8px 10px; border-bottom:1px solid var(--line); }
  th { color:var(--muted); font-weight:600; }
  code { background:var(--code-bg); padding:1px 5px; border-radius:5px; font:.9em Consolas, "Courier New", monospace; word-break:break-all; }
  .warn { background:var(--warn-bg); border-left:4px solid var(--warn); padding:10px 14px; border-radius:6px; margin:10px 0; }
  a { color:var(--accent); }
</style>"""


def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', lambda m: '<code>' + m.group(1) + '</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', t)
    t = re.sub(r'(?<!["=/])(https?://[^\s<)]+)', r'<a href="\1">\1</a>', t)
    return t


def convert(md_text, title_fallback='switchback'):
    lines = md_text.splitlines()
    title, sub, sections, intro = '', [], [], []
    cur = None
    i, n = 0, len(lines)

    def out(s):
        (cur[2] if cur else intro).append(s)

    def item_html(text, subs):
        h = inline(text)
        if subs:
            h += '<ul>' + ''.join('<li>%s</li>' % inline(s) for s in subs) + '</ul>'
        return '<li>%s</li>' % h

    while i < n:
        l = lines[i]
        if l.startswith('# ') and not title:
            title = l[2:].strip(); i += 1
            while i < n and lines[i].strip() and not lines[i].startswith('#'):
                sub.append(lines[i].strip()); i += 1
            continue
        if l.strip() in ('', '---'):
            i += 1; continue
        if l.startswith('## '):
            t = l[3:].strip()
            cur = ('s%d' % len(sections), t, [])
            sections.append(cur)
            out('<h2 id="%s">%s</h2>' % (cur[0], inline(t))); i += 1; continue
        if l.startswith('### '):
            out('<h3>%s</h3>' % inline(l[4:].strip())); i += 1; continue
        if l.startswith('>'):
            q = []
            while i < n and lines[i].startswith('>'):
                q.append(lines[i][1:].strip()); i += 1
            out('<div class="warn">%s</div>' % inline(' '.join(q))); continue
        if l.startswith('|'):
            rows = []
            while i < n and lines[i].startswith('|'):
                rows.append([c.strip() for c in lines[i].strip().strip('|').split('|')]); i += 1
            head = rows[0]
            body = [r for r in rows[1:] if not all(re.fullmatch(r':?-+:?', c) for c in r)]
            out('<div class="table-wrap"><table><thead><tr>' + ''.join('<th>%s</th>' % inline(c) for c in head)
                + '</tr></thead><tbody>' + ''.join('<tr>' + ''.join('<td>%s</td>' % inline(c) for c in r) + '</tr>' for r in body)
                + '</tbody></table></div>')
            continue
        m = re.match(r'^(\d+)\. (.*)', l)
        if m or l.startswith('- '):
            tag = 'ol' if m else 'ul'
            items = []   # [text, [sub items]]
            while i < n:
                l = lines[i]
                m2 = re.match(r'^(\d+)\. (.*)', l)
                if tag == 'ol' and m2:
                    items.append([m2.group(2), []]); i += 1
                elif tag == 'ul' and l.startswith('- '):
                    items.append([l[2:], []]); i += 1
                elif re.match(r'^\s{2,}- ', l) and items:
                    items[-1][1].append(l.strip()[2:]); i += 1
                elif l.startswith('  ') and l.strip() and items:
                    if items[-1][1]:
                        items[-1][1][-1] += ' ' + l.strip()
                    else:
                        items[-1][0] += ' ' + l.strip()
                    i += 1
                else:
                    break
            out('<%s>%s</%s>' % (tag, ''.join(item_html(t, s) for t, s in items), tag))
            continue
        para = [l.strip()]; i += 1
        while i < n and lines[i].strip() and not re.match(r'^(#|\||- |\d+\. |---|>)', lines[i]):
            para.append(lines[i].strip()); i += 1
        out('<p>%s</p>' % inline(' '.join(para)))

    nav = '<nav><ol>' + ''.join('<li><a href="#%s">%s</a></li>' % (s[0], inline(s[1])) for s in sections) + '</ol></nav>'
    body = ''.join(intro) and '<section>%s</section>\n' % ''.join(intro)
    body += ''.join('<section>%s</section>\n' % ''.join(s[2]) for s in sections)
    return ('<!doctype html>\n<html lang="ru">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>' + html.escape(title or title_fallback)
            + '</title>\n' + STYLE + '\n</head>\n<body>\n<main>\n<h1>' + inline(title) + '</h1>\n'
            + ('<p class="sub">' + inline(' '.join(sub)) + '</p>\n' if sub else '') + nav + '\n' + body + '</main>\n</body>\n</html>\n')


if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    page = convert(open(src, encoding='utf-8').read())
    open(dst, 'w', encoding='utf-8', newline='\n').write(page)
    print(dst, len(page.encode('utf-8')), 'bytes')
