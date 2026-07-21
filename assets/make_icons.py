import cairosvg, struct, os

os.makedirs("out", exist_ok=True)

# App icon: render PNGs at required sizes, pack into ICNS (PNG-in-ICNS is valid for these types)
sizes = {
    "icp4": 16, "icp5": 32, "icp6": 64,
    "ic07": 128, "ic08": 256, "ic09": 512, "ic10": 1024,
    "ic11": 32,  # 16@2x
    "ic12": 64,  # 32@2x
    "ic13": 512, # 256@2x
    "ic14": 1024 # 512@2x
}
chunks = b""
for typ, px in sizes.items():
    png = cairosvg.svg2png(url="icon-corgi.svg", output_width=px, output_height=px)
    chunks += typ.encode() + struct.pack(">I", 8 + len(png)) + png

icns = b"icns" + struct.pack(">I", 8 + len(chunks)) + chunks
with open("out/AppIcon.icns", "wb") as f:
    f.write(icns)

# 1024 marketing png too
cairosvg.svg2png(url="icon-corgi.svg", output_width=1024, output_height=1024, write_to="out/icon-1024.png")

# Menubar template icons (black on transparent), 18pt logical size
cairosvg.svg2png(url="menubar.svg", output_width=18, output_height=18, write_to="out/menubar.png")
cairosvg.svg2png(url="menubar.svg", output_width=36, output_height=36, write_to="out/menubar@2x.png")

print("icns bytes:", len(icns))
