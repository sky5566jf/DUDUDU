import re

mm_path = 'F:/workbuddy/TrollVNC-main/src/TVNCHttpServer.mm'
b64_path = 'F:/workbuddy/TrollVNC-main/src/new_webdav_base64.txt'

# Read the new base64 lines
with open(b64_path, 'r', encoding='ascii') as f:
    new_b64_lines = f.read()

# Read the .mm file
with open(mm_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Find the start of kWebDAVHTMLBase64
start_marker = 'static NSString * const kWebDAVHTMLBase64 ='
start_idx = content.find(start_marker)
if start_idx == -1:
    print('ERROR: kWebDAVHTMLBase64 not found')
    exit(1)

# Find the = sign position
equals_idx = content.find('=', start_idx)
if equals_idx == -1:
    print('ERROR: = not found')
    exit(1)

# Find the end: look for '";' after the base64 starts
# The base64 section ends with a line like:     @"......";
# We need to find the LAST @" in that section

# Strategy: find the line with `kWebDAVHTMLBase64 =`, then find all subsequent @"..." lines
# until we hit a line that ends with '";' (not '",')
# Actually in the file, each line is:     @"BASE64", (with comma) except last which is     @"BASE64";

# Let me find the end by looking for the pattern after the start
# The base64 section ends when we find a line that has @"" followed by "; (not ",")
# Actually looking at the original: each intermediate line ends with '",' and the last ends with '";'

# Let me use a regex approach: find everything from `=` to the first `";` that follows `@"`
# Actually the format is:
# static NSString * const kWebDAVHTMLBase64 =
#     @"..."
#     @"..."
#     ..
#     @"...";

# Find the start of the first @" after =
search_start = equals_idx + 1
first_at_idx = content.find('@"', search_start)
if first_at_idx == -1:
    print('ERROR: first @" not found')
    exit(1)

# Now find the end: look for '";' after first_at_idx
# But there could be many @"..." lines. The last one ends with '";'
# Let me find the LAST @"..." line by scanning from first_at_idx

# Actually, let me just find the position of '";' after the start of the base64
# The base64 strings are consecutive. The end is marked by `";` (not `",`)
# Let me find all @" occurrences after first_at_idx and find the last one

# Simpler: replace from `=` to the end of the last @"..." line
# Find: everything from `=` to the next `";` that is preceded by @"`

# Let me use a different approach: find the line number / position of the LAST @"..." line
# After `kWebDAVHTMLBase64 =`, the base64 lines continue until a line ending with '";'

# Read line by line
lines = content.split('\n')
in_b64 = False
end_idx = None
for i, line in enumerate(lines):
    if 'kWebDAVHTMLBase64' in line and '=' in line:
        in_b64 = True
        continue
    if in_b64:
        if line.strip().endswith('";'):
            end_idx = i
            break
        elif line.strip().endswith('",'):
            continue
        else:
            # Unexpected - maybe the base64 ended
            print(f'Unexpected line in base64 section: {line[:80]}')
            break

if end_idx is None:
    print('ERROR: could not find end of base64 section')
    exit(1)

print(f'Base64 section: line {content[:content.find("kWebDAVHTMLBase64")].count(chr(10))+1} to line {end_idx+1}')

# Now replace: from after `=` to end_idx
# Actually let me rebuild the file content
# 
# Lines before the base64 value start:
pre_lines = []
in_b64_replacement = False
skip_until_end = False
new_lines = []
replace_done = False

for i, line in enumerate(lines):
    if not replace_done:
        if 'kWebDAVHTMLBase64' in line and '=' in line:
            new_lines.append(line)
            # Next lines are the base64 - skip them and insert new ones
            skip_until_end = True
            continue
        if skip_until_end:
            if line.strip().endswith('";'):
                # This is the last base64 line - replace with new content
                # Add the new base64 lines
                for b64_line in new_b64_lines.split('\n'):
                    b64_line = b64_line.rstrip('\n')
                    if b64_line:
                        new_lines.append(b64_line)
                replace_done = True
                skip_until_end = False
            # Skip all base64 lines
            continue
    new_lines.append(line)

if not replace_done:
    print('ERROR: replacement failed - end of base64 not found')
    exit(1)

new_content = '\n'.join(new_lines)

# Verify the new content has the base64
if 'kWebDAVHTMLBase64' in new_content:
    print('SUCCESS: replacement done')
    # Count lines
    n_b64_lines = new_b64_lines.strip().count('\n') + 1
    print(f'New base64: {n_b64_lines} lines')
else:
    print('ERROR: kWebDAVHTMLBase64 missing after replacement')
    exit(1)

# Write back
with open(mm_path, 'w', encoding='utf-8') as f:
    f.write(new_content)

print(f'Written to {mm_path}')
