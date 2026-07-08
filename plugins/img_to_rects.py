import sys
import urllib.request
import os

try:
    from PIL import Image
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'pillow'])
    from PIL import Image

def image_to_lua_rects(img_path, out_path, max_width=250, max_height=250):
    temp_img = None
    try:
        # If it's a URL, download it first
        if img_path.startswith('http://') or img_path.startswith('https://'):
            temp_img = out_path + ".img"
            urllib.request.urlretrieve(img_path, temp_img)
            img_path = temp_img

        img = Image.open(img_path).convert('RGB')
        
        # Resize preserving aspect ratio
        img.thumbnail((max_width, max_height), Image.Resampling.LANCZOS)
        
        width, height = img.size
        pixels = img.load()
        img.close()
        
        rects = []
        for y in range(height):
            x = 0
            while x < width:
                r, g, b = pixels[x, y]
                # Find run length of similar color
                run = 1
                while x + run < width:
                    nr, ng, nb = pixels[x + run, y]
                    # Color distance threshold for compression
                    if abs(r-nr) + abs(g-ng) + abs(b-nb) < 15:
                        run += 1
                    else:
                        break
                
                rects.append(f"{{{x},{y},{run},{r},{g},{b}}}")
                x += run
                
        # Write to Lua file
        with open(out_path, 'w') as f:
            f.write("return {\n")
            f.write(f"  w={width}, h={height},\n")
            f.write("  rects={\n")
            f.write(",\n".join(rects))
            f.write("\n  }\n}\n")
            
    except Exception as e:
        with open(out_path, 'w') as f:
            f.write(f'return {{ error = "{str(e)}" }}')
            
    finally:
        if temp_img and os.path.exists(temp_img):
            try:
                os.remove(temp_img)
            except:
                pass

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python img_to_rects.py <in_img> <out_lua> [max_width] [max_height]")
        sys.exit(1)
        
    max_w = int(sys.argv[3]) if len(sys.argv) > 3 else 250
    max_h = int(sys.argv[4]) if len(sys.argv) > 4 else 250
    
    image_to_lua_rects(sys.argv[1], sys.argv[2], max_w, max_h)
