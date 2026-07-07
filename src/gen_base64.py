import base64

# Read the HTML file with install buttons
html_path = 'F:/workbuddy/TrollVNC-main/layout/var/mobile/Library/MatisuXCS/webdav.html'
output_path = 'F:/workbuddy/TrollVNC-main/src/new_webdav_base64.txt'

with open(html_path, 'r', encoding='utf-8') as f:
    html_content = f.read()

# Base64 encode (no newlines)
b64 = base64.b64encode(html_content.encode('utf-8')).decode('ascii')
print(f'HTML length: {len(html_content)}')
print(f'Base64 length: {len(b64)}')

# Split into lines of ~2360 chars each (matching original format)
CHUNK = 2360
lines = [b64[i:i+CHUNK] for i in range(0, len(b64), CHUNK)]

# Write as Obj-C string literals
with open(output_path, 'w', encoding='ascii') as f:
    f.write('    @"' + lines[0] + '",\n')
    for line in lines[1:-1]:
        f.write('    @"' + line + '",\n')
    f.write('    @"' + lines[-1] + '";\n')

print(f'Written {len(lines)} lines to {output_path}')
print(f'First 80 chars of b64: {b64[:80]}')
print(f'Last 80 chars of b64: {b64[-80:]}')
