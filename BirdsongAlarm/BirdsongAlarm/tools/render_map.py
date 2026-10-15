"""Render a full-resolution Natural Earth 10m world map (Mercator) plus one
cropped transparent highlight layer per bird region. No simplification.

Usage: python render_map.py <data_dir> <out_dir>
  data_dir needs world-atlas@2.0.2 countries-10m.json and us-atlas@3.0.1 states-10m.json.
  Region crop frames are written to out_dir/frames.json (mirror them in RegionSelectView.swift)."""
import json, math, os, sys
from shapely.geometry import shape, box, Polygon, MultiPolygon
from shapely.ops import unary_union
from PIL import Image, ImageDraw

DL = sys.argv[1]
OUT = sys.argv[2]
os.makedirs(OUT, exist_ok=True)

W = 3000                    # final width in px
SS = 2                      # supersampling factor
LAT_N, LAT_S = 84.0, -58.0

OCEAN = (0, 0, 0, 255)
LAND = (18, 18, 18, 255)
BORDER = (255, 214, 10, 255)
HILITE = (255, 214, 10, 255)
HILITE_EDGE = (0, 0, 0, 255)

def merc_y(lat):
    phi = math.radians(lat)
    return math.log(math.tan(math.pi / 4 + phi / 2))

Y_N, Y_S = merc_y(LAT_N), merc_y(LAT_S)
H = round(W * (Y_N - Y_S) / (2 * math.pi))

def proj(lon, lat, scale):
    lat = max(min(lat, 89.0), -89.0)
    x = (lon + 180.0) / 360.0 * W * scale
    y = (Y_N - merc_y(lat)) / (Y_N - Y_S) * H * scale
    return (x, y)

def split_antimeridian(p):
    minx, _, maxx, _ = p.bounds
    if maxx - minx <= 180:
        return [p]
    from shapely.affinity import translate
    sh = lambda r: [(x + 360 if x < 0 else x, y) for x, y in r.coords]
    q = Polygon(sh(p.exterior), [sh(i) for i in p.interiors]).buffer(0)
    east = q.intersection(box(0, -90, 180, 90))
    west = translate(q.intersection(box(180, -90, 540, 90)), xoff=-360)
    out = []
    for g in (east, west):
        out += [g] if isinstance(g, Polygon) else [x for x in getattr(g, "geoms", []) if isinstance(x, Polygon)]
    return [x for x in out if not x.is_empty]

# ── TopoJSON decode ─────────────────────────────────────────────────────────
def topo_features(path, obj):
    topo = json.load(open(path, encoding="utf-8"))
    sx, sy = topo["transform"]["scale"]
    tx, ty = topo["transform"]["translate"]
    arcs = []
    for arc in topo["arcs"]:
        x = y = 0; pts = []
        for dx, dy in arc:
            x += dx; y += dy
            pts.append((x * sx + tx, y * sy + ty))
        arcs.append(pts)
    def ring(ids):
        out = []
        for i in ids:
            seg = arcs[i] if i >= 0 else arcs[~i][::-1]
            out.extend(seg[1:] if out else seg)
        return out
    def poly(rs):
        rings = [ring(r) for r in rs]
        rings = [r for r in rings if len(r) >= 4]
        if not rings or len(ring(rs[0])) < 4:
            return None
        return Polygon(rings[0], rings[1:])
    feats = []
    for g in topo["objects"][obj]["geometries"]:
        if g["type"] == "Polygon":
            ps = [poly(g["arcs"])]
        elif g["type"] == "MultiPolygon":
            ps = [poly(p) for p in g["arcs"]]
        else:
            continue
        ps = [q for p in ps if p is not None for q in split_antimeridian(p)]
        if not ps:
            continue
        s = ps[0] if len(ps) == 1 else MultiPolygon(ps)
        if not s.is_valid:
            s = s.buffer(0)
        feats.append((str(g.get("id", "")), g.get("properties", {}).get("name", ""), s))
    return feats

countries = topo_features(os.path.join(DL, "countries-10m.json"), "countries")
states = topo_features(os.path.join(DL, "states-10m.json"), "states")

# ── Region membership (a country may belong to more than one region) ────────
REGIONS = {
 "eastern_na": ["Greenland", "Bermuda", "St. Pierre and Miquelon"],
 "western_na": [],
 "central_america": ["Mexico", "Guatemala", "Belize", "Honduras", "El Salvador", "Nicaragua",
    "Costa Rica", "Panama", "Cuba", "Jamaica", "Haiti", "Dominican Rep.", "Puerto Rico",
    "Bahamas", "Turks and Caicos Is.", "Cayman Is.", "British Virgin Is.", "U.S. Virgin Is.",
    "Anguilla", "St-Martin", "Sint Maarten", "St-Barthélemy", "Antigua and Barb.",
    "St. Kitts and Nevis", "Montserrat", "Dominica", "Saint Lucia", "St. Vin. and Gren.",
    "Grenada", "Barbados", "Trinidad and Tobago", "Aruba", "Curaçao", "USNB Guantanamo Bay",
    "Bajo Nuevo Bank", "Serranilla Bank", "Clipperton I."],
 "amazonia": ["Brazil", "Colombia", "Venezuela", "Guyana", "Suriname", "Ecuador", "Peru", "Bolivia"],
 "andes_pacific_sa": ["Venezuela", "Colombia", "Ecuador", "Peru", "Bolivia", "Chile"],
 "southern_sa": ["Argentina", "Uruguay", "Paraguay", "Falkland Is.", "S. Geo. and the Is."],
 "western_europe": ["United Kingdom", "Ireland", "Isle of Man", "Jersey", "Guernsey", "France",
    "Spain", "Portugal", "Andorra", "Gibraltar", "Italy", "Vatican", "San Marino", "Malta",
    "Monaco", "Germany", "Belgium", "Netherlands", "Luxembourg", "Switzerland", "Liechtenstein",
    "Austria", "Denmark", "Faeroe Is.", "Norway", "Sweden", "Finland", "Åland", "Iceland",
    "Czechia", "Slovakia", "Hungary", "Slovenia", "Croatia", "Bosnia and Herz.", "Serbia",
    "Montenegro", "Kosovo", "Macedonia", "Albania", "Greece", "Romania", "Bulgaria"],
 "eastern_europe": ["Russia", "Ukraine", "Belarus", "Poland", "Lithuania", "Latvia", "Estonia",
    "Moldova", "Georgia", "Armenia", "Azerbaijan", "Kazakhstan", "Baikonur", "Kyrgyzstan",
    "Tajikistan", "Uzbekistan", "Turkmenistan", "Mongolia"],
 "mena": ["Morocco", "W. Sahara", "Algeria", "Tunisia", "Libya", "Egypt", "Turkey", "Cyprus",
    "N. Cyprus", "Cyprus U.N. Buffer Zone", "Akrotiri", "Dhekelia", "Syria", "Lebanon", "Israel",
    "Palestine", "Jordan", "Iraq", "Iran", "Kuwait", "Saudi Arabia", "Bahrain", "Qatar",
    "United Arab Emirates", "Oman", "Yemen", "Afghanistan"],
 "west_central_africa": ["Mauritania", "Senegal", "Gambia", "Guinea-Bissau", "Guinea",
    "Sierra Leone", "Liberia", "Côte d'Ivoire", "Ghana", "Togo", "Benin", "Nigeria", "Mali",
    "Burkina Faso", "Niger", "Chad", "Cameroon", "Central African Rep.", "Eq. Guinea", "Gabon",
    "Congo", "Dem. Rep. Congo", "Angola", "Cabo Verde", "São Tomé and Principe", "Saint Helena"],
 "east_africa": ["Sudan", "S. Sudan", "Eritrea", "Djibouti", "Ethiopia", "Somalia", "Somaliland",
    "Kenya", "Uganda", "Rwanda", "Burundi", "Tanzania"],
 "southern_africa": ["South Africa", "Lesotho", "eSwatini", "Namibia", "Botswana", "Zimbabwe",
    "Zambia", "Malawi", "Mozambique", "Madagascar", "Comoros", "Mauritius", "Seychelles"],
 "south_asia": ["India", "Pakistan", "Nepal", "Bhutan", "Bangladesh", "Sri Lanka", "Maldives",
    "Siachen Glacier", "Br. Indian Ocean Ter."],
 "southeast_asia": ["Myanmar", "Thailand", "Laos", "Cambodia", "Vietnam", "Malaysia", "Singapore",
    "Brunei", "Indonesia", "Philippines", "Timor-Leste", "Papua New Guinea", "Spratly Is.",
    "Scarborough Reef", "Indian Ocean Ter."],
 "east_asia": ["China", "Hong Kong", "Macao", "Taiwan", "Japan", "North Korea", "South Korea"],
 "australia": ["Australia", "Ashmore and Cartier Is.", "Coral Sea Is."],
 "nz_pacific": ["New Zealand", "Fiji", "Solomon Is.", "Vanuatu", "New Caledonia", "Samoa",
    "American Samoa", "Tonga", "Niue", "Cook Is.", "Fr. Polynesia", "Pitcairn Is.",
    "Wallis and Futuna Is.", "Tuvalu", "Kiribati", "Nauru", "Marshall Is.", "Micronesia",
    "Palau", "Guam", "N. Mariana Is.", "Norfolk Island", "U.S. Minor Outlying Is."],
}

by_name = {n: g for _, n, g in countries}
missing = [n for ns in REGIONS.values() for n in ns if n not in by_name]
print("Not drawable:", missing)
assigned = {n for ns in REGIONS.values() for n in ns} | {"United States of America", "Canada"}
print("Unassigned:", sorted(set(by_name) - assigned))

region_geoms = {rid: [by_name[n] for n in names if n in by_name] for rid, names in REGIONS.items()}

# France / Netherlands: route overseas parts by location
def parts(g):
    return list(g.geoms) if isinstance(g, MultiPolygon) else [g]

by_name["Norway"] = MultiPolygon([p for p in parts(by_name["Norway"]) if p.representative_point().y > 0])
region_geoms["western_europe"] = [by_name[n] for n in REGIONS["western_europe"] if n in by_name]

for country in ("France", "Netherlands"):
    home = []
    for p in parts(by_name[country]):
        c = p.representative_point()
        if c.x < -30 and -56 < c.x < -51 and c.y < 10:
            region_geoms["amazonia"].append(p)
        elif c.x < -30:
            region_geoms["central_america"].append(p)
        elif c.x > 40 and c.y < 0:
            region_geoms["southern_africa"].append(p)
        else:
            home.append(p)
    region_geoms["western_europe"] = [g for g in region_geoms["western_europe"] if g is not by_name[country]]
    region_geoms["western_europe"].append(MultiPolygon(home) if len(home) > 1 else home[0])

# United States: split along state lines
WEST_FIPS = {"53", "41", "06", "32", "16", "30", "56", "49", "08", "04", "35", "02"}
st = {sid: g for sid, _, g in states}
west_mask = unary_union([st[f] for f in WEST_FIPS]).buffer(0.05)
hawaii_mask = st["15"].buffer(0.3)
usa = by_name["United States of America"]
us_west = usa.intersection(west_mask)
us_hawaii = usa.intersection(hawaii_mask)
us_east = usa.intersection(box(-125, 15, -60, 50)).difference(west_mask).difference(hawaii_mask)
us_west = usa.difference(us_east).difference(hawaii_mask)
region_geoms["western_na"].append(us_west)
region_geoms["eastern_na"].append(us_east)
region_geoms["nz_pacific"].append(us_hawaii)

# Canada: split along the Saskatchewan / Manitoba boundary (~102°W)
can = by_name["Canada"]
west_can = Polygon([(-150, 40), (-101.36, 40), (-101.36, 49), (-102.0, 60), (-102.0, 90), (-150, 90)])
region_geoms["western_na"].append(can.intersection(west_can))
region_geoms["eastern_na"].append(can.difference(west_can))

# ── Drawing helpers ─────────────────────────────────────────────────────────
def polys(g):
    if g.is_empty:
        return []
    if isinstance(g, Polygon):
        return [g]
    if isinstance(g, MultiPolygon):
        return list(g.geoms)
    return [p for sub in getattr(g, "geoms", []) for p in polys(sub)]

def fill(img, geoms, color, off=(0, 0)):
    mask = Image.new("L", img.size, 0)
    d = ImageDraw.Draw(mask)
    ox, oy = off
    for g in geoms:
        for p in polys(g):
            d.polygon([(x - ox, y - oy) for x, y in (proj(*c, SS) for c in p.exterior.coords)], fill=255)
            for hole in p.interiors:
                d.polygon([(x - ox, y - oy) for x, y in (proj(*c, SS) for c in hole.coords)], fill=0)
    layer = Image.new("RGBA", img.size, color)
    img.paste(layer, (0, 0), mask)

def outline(img, geoms, color, width, off=(0, 0)):
    d = ImageDraw.Draw(img)
    ox, oy = off
    for g in geoms:
        for p in polys(g):
            for r in [p.exterior, *p.interiors]:
                pts = [(x - ox, y - oy) for x, y in (proj(*c, SS) for c in r.coords)]
                d.line(pts, fill=color, width=width, joint="curve")

# ── Base map ────────────────────────────────────────────────────────────────
all_land = [g for _, n, g in countries if n != "Antarctica"]
base = Image.new("RGBA", (W * SS, H * SS), OCEAN)
fill(base, all_land, LAND)
outline(base, all_land, BORDER, 2)
base.resize((W, H), Image.LANCZOS).convert("RGB").save(os.path.join(OUT, "MapBase.png"), optimize=True)
print(f"MapBase.png {W}x{H}")

# ── Region highlight layers (cropped to bbox) ───────────────────────────────
frames = {}
PAD = 6 * SS
for rid, geoms in region_geoms.items():
    xs, ys = [], []
    for g in geoms:
        for p in polys(g):
            for c in p.exterior.coords:
                x, y = proj(*c, SS); xs.append(x); ys.append(y)
    x0 = max(0, int(min(xs)) - PAD) // SS * SS
    y0 = max(0, int(min(ys)) - PAD) // SS * SS
    x1 = min(W * SS, -(-(int(max(xs)) + PAD) // SS) * SS)
    y1 = min(H * SS, -(-(int(max(ys)) + PAD) // SS) * SS)
    img = Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 0))
    fill(img, geoms, HILITE, (x0, y0))
    outline(img, geoms, HILITE_EDGE, 2, (x0, y0))
    img = img.resize(((x1 - x0) // SS, (y1 - y0) // SS), Image.LANCZOS)
    img.save(os.path.join(OUT, f"Region_{rid}.png"), optimize=True)
    frames[rid] = [x0 / SS / W, y0 / SS / H, (x1 - x0) / SS / W, (y1 - y0) / SS / H]
    print(f"Region_{rid}.png {img.size}")

json.dump({"width": W, "height": H, "frames": frames}, open(os.path.join(OUT, "frames.json"), "w"), indent=1)
