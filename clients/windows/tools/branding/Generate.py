# SPDX-License-Identifier: AGPL-3.0-or-later
"""Deterministic raster export of the original SVG, not a modification of third-party art."""
from pathlib import Path
import io
import cairosvg
from PIL import Image
root = Path(__file__).resolve().parents[2] / 'src/OpenWebPbx.Phone.App/Assets'
source = (root / 'Brand.svg').read_bytes()
def logo(size):
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=source, output_width=size, output_height=size))).convert('RGBA')
# The direct MakeAppx route also needs the literal 100% manifest resources;
# the scale-qualified variants alone require a matching resource index.
for name, size in [('Square150x150Logo.png',150), ('Square44x44Logo.png',44), ('Square150x150Logo.scale-200.png',300), ('Square44x44Logo.scale-200.png',88), ('Square44x44Logo.targetsize-24_altform-unplated.png',24), ('Square44x44Logo.targetsize-48_altform-lightunplated.png',48), ('StoreLogo.png',50), ('LockScreenLogo.scale-200.png',48)]:
    logo(size).save(root / name)
for name, dimensions, size in [('SplashScreen.png',(620,300),100), ('Wide310x150Logo.png',(310,150),80), ('SplashScreen.scale-200.png',(1240,600),200), ('Wide310x150Logo.scale-200.png',(620,300),160)]:
    image = Image.new('RGBA',dimensions,(0,0,0,0)); image.alpha_composite(logo(size), ((dimensions[0]-size)//2,(dimensions[1]-size)//2)); image.save(root/name)
logo(256).save(root/'AppIcon.ico',format='ICO',sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
