#!/usr/bin/env python3
"""Generator for HungerGamesSandbox.tscn.

Hand-authoring the spawn-circle and the spiral spire branches means a lot of
rotation matrices, so we compute them here and emit a plain Godot .tscn. Re-run
after tweaking the layout constants below.
"""
import math

OUT = "Screens/Maps/HungerGamesSandbox.tscn"

# ---- external resources (uids copied from the existing sandbox maps) ----
EXT = [
    ('Material',    'uid://dmqveijwescc', 'res://Assets/Textures/Prototype/grid.tres',        '1_grid'),
    ('Material',    'uid://by0fj5s5fgaqa', 'res://Assets/Textures/Prototype/grid2.tres',       '2_grid2'),
    ('PackedScene', 'uid://1xfx84i2ndhj',  'res://Components/Dodgeball/dodgeball.tscn',         '3_ball'),
    ('Script',      'uid://cecy85ew5gbd3',  'res://Components/SpawnPoints/spawn_points.gd',     '4_spawn'),
    ('PackedScene', 'uid://waof3iv58jdc',  'res://Components/SpawnPoints/SpawnPoint.tscn',      '5_sp'),
    ('PackedScene', 'uid://h4khs4eb658e',  'res://Components/CaptureTheFlag/base.tscn',         '6_base'),
    ('PackedScene', 'uid://w6qvq64q0bhm',  'res://Components/Flag/flag.tscn',                   '7_flag'),
]

lines = []
sub = []   # sub-resource blocks
nodes = []  # node blocks


def fmt(v):
    return ("%.5f" % v).rstrip('0').rstrip('.') if isinstance(v, float) else str(v)


def xform(basis_x, basis_y, basis_z, o):
    nums = list(basis_x) + list(basis_y) + list(basis_z) + list(o)
    return "Transform3D(" + ", ".join(fmt(n) for n in nums) + ")"


def translate(o):
    return xform((1, 0, 0), (0, 1, 0), (0, 0, 1), o)


def yaw(theta, o):
    c, s = math.cos(theta), math.sin(theta)
    return xform((c, 0, -s), (0, 1, 0), (s, 0, c), o)


def look_at_center(pos):
    # Marker forward is -Z; aim it at the arena centre (origin in XZ).
    f = (-pos[0], 0.0, -pos[2])
    n = math.hypot(f[0], f[2]) or 1.0
    f = (f[0] / n, 0.0, f[2] / n)
    z = (-f[0], 0.0, -f[2])           # local +Z
    x = (z[2], 0.0, -z[0])            # cross(up, z)
    y = (0.0, 1.0, 0.0)
    return xform(x, y, z, pos)


def box(name, parent, size, transform, mat, collision=True):
    b = [f'[node name="{name}" type="CSGBox3D" parent="{parent}"]',
         f'transform = {transform}']
    if collision:
        b.append('use_collision = true')
    b.append(f'size = Vector3({fmt(size[0])}, {fmt(size[1])}, {fmt(size[2])})')
    b.append(f'material = {mat}')
    nodes.append("\n".join(b))


def ring(parent, prefix, a, b, top, mat):
    # Solid square annulus (4 strips) from half-extent a to b, top surface at `top`,
    # resting on the baseplate (y=0). Each step rim is <1m tall so players can hop it.
    h = top
    cy = top / 2.0
    mid = (a + b) / 2.0
    w = b - a
    box(f'{prefix}N', parent, (2 * b, h, w), translate((0, cy, -mid)), mat)
    box(f'{prefix}S', parent, (2 * b, h, w), translate((0, cy, mid)), mat)
    box(f'{prefix}E', parent, (w, h, 2 * a), translate((mid, cy, 0)), mat)
    box(f'{prefix}W', parent, (w, h, 2 * a), translate((-mid, cy, 0)), mat)


# ----- materials -----
sub.append('[sub_resource type="ProceduralSkyMaterial" id="Sky_mat"]\n'
           'sky_top_color = Color(0.38, 0.6, 0.86, 1)\n'
           'sky_horizon_color = Color(0.7, 0.8, 0.7, 1)\n'
           'ground_horizon_color = Color(0.55, 0.6, 0.45, 1)\n'
           'ground_bottom_color = Color(0.3, 0.35, 0.2, 1)')
sub.append('[sub_resource type="Sky" id="Sky"]\nsky_material = SubResource("Sky_mat")')
sub.append('[sub_resource type="Environment" id="Env"]\n'
           'background_mode = 2\nsky = SubResource("Sky")\ntonemap_mode = 2\nglow_enabled = true')
sub.append('[sub_resource type="StandardMaterial3D" id="Mat_trunk"]\n'
           'albedo_color = Color(0.36, 0.24, 0.13, 1)\nroughness = 0.95')
sub.append('[sub_resource type="StandardMaterial3D" id="Mat_branch"]\n'
           'albedo_color = Color(0.47, 0.33, 0.18, 1)\nroughness = 0.9')
sub.append('[sub_resource type="StandardMaterial3D" id="Mat_leaf"]\n'
           'albedo_color = Color(0.2, 0.45, 0.17, 1)\nroughness = 1.0')

GRID = 'ExtResource("1_grid")'
GRID2 = 'ExtResource("2_grid2")'
TRUNK = 'SubResource("Mat_trunk")'
BRANCH = 'SubResource("Mat_branch")'
LEAF = 'SubResource("Mat_leaf")'

# ----- root, env, light -----
nodes.append('[node name="HungerGamesSandbox" type="Node3D"]')
nodes.append('[node name="WorldEnvironment" type="WorldEnvironment" parent="."]\n'
             'environment = SubResource("Env")')
nodes.append('[node name="DirectionalLight3D" type="DirectionalLight3D" parent="."]\n'
             'transform = Transform3D(-0.8660254, -0.43301278, 0.25, 0, 0.49999997, 0.86602545, '
             '-0.50000006, 0.75, -0.43301266, 0, 20, 0)\nshadow_enabled = true')

# ----- arena: baseplate + stepped bowl -----
nodes.append('[node name="Arena" type="Node3D" parent="."]')
# Solid baseplate: top at y=0 covers the whole footprint; the centre field sits on it.
box('Baseplate', 'Arena', (96, 1, 96), translate((0, -0.5, 0)), GRID)
# Concentric rims rising outward -> a shallow bowl. Centre field (r<8) stays at y=0.
ring('Arena', 'RimInner',  8, 14, 0.4, GRID2)   # field -> step 1
ring('Arena', 'RimMid',   14, 20, 0.8, GRID2)   # step 1 -> step 2
ring('Arena', 'Plain',    20, 46, 1.2, GRID)    # step 2 -> outer plain (spawns + spires)

# Low perimeter lip so players don't run off the plain edge.
LIP_H = 1.5
box('WallN', 'Arena', (94, LIP_H, 1), translate((0, 1.2 + LIP_H / 2, -46)), GRID2)
box('WallS', 'Arena', (94, LIP_H, 1), translate((0, 1.2 + LIP_H / 2, 46)), GRID2)
box('WallE', 'Arena', (1, LIP_H, 94), translate((46, 1.2 + LIP_H / 2, 0)), GRID2)
box('WallW', 'Arena', (1, LIP_H, 94), translate((-46, 1.2 + LIP_H / 2, 0)), GRID2)

# ----- tree-like spires with climbable spiral branches -----
nodes.append('[node name="Spires" type="Node3D" parent="."]')
PLAIN_Y = 1.2
SPIRE_COUNT = 6
SPIRE_R = 33.0
TRUNK_H = 11.0
BRANCHES = 11
BRANCH_RISE = 0.8        # <1m per step so each branch is reachable from the one below
FIRST_BRANCH_TOP = PLAIN_Y + 0.7
for i in range(SPIRE_COUNT):
    a = 2 * math.pi * i / SPIRE_COUNT + 0.5
    sx, sz = SPIRE_R * math.cos(a), SPIRE_R * math.sin(a)
    p = f'Spires/Spire{i + 1}'
    nodes.append(f'[node name="Spire{i + 1}" type="Node3D" parent="Spires"]\n'
                 f'transform = {translate((sx, 0, sz))}')
    box('Trunk', p, (1.3, TRUNK_H, 1.3), translate((0, PLAIN_Y + TRUNK_H / 2, 0)), TRUNK)
    for b in range(BRANCHES):
        top = FIRST_BRANCH_TOP + b * BRANCH_RISE
        cy = top - 0.15
        theta = b * (2 * math.pi / 5)        # spiral: 72 degrees per branch
        reach = 1.05
        bx = reach * math.cos(theta)
        bz = -reach * math.sin(theta)         # matches local +X under yaw(theta)
        box(f'Branch{b + 1}', p, (2.2, 0.3, 0.6), yaw(theta, (bx, cy, bz)), BRANCH, collision=True)
    # foliage cap
    nodes.append(f'[node name="Canopy" type="CSGSphere3D" parent="{p}"]\n'
                 f'transform = {translate((0, PLAIN_Y + TRUNK_H + 1.2, 0))}\n'
                 f'radius = 3.0\nmaterial = {LEAF}')

# ----- dodgeballs in the flat centre field -----
nodes.append('[node name="Dodgeballs" type="Node3D" parent="."]')
ball_spots = [(0, 0), (2.5, 0), (-2.5, 0), (0, 2.5), (0, -2.5),
              (2, 2), (-2, 2), (2, -2), (-2, -2)]
for i, (bx, bz) in enumerate(ball_spots):
    nodes.append(f'[node name="Ball{i + 1}" parent="Dodgeballs" instance=ExtResource("3_ball")]\n'
                 f'transform = {translate((bx, 0.5, bz))}')

# ----- CTF bases + flags (kept so CTF mode still works when this is the sandbox) -----
nodes.append('[node name="RedBase" parent="." node_paths=PackedStringArray("flag") '
             'instance=ExtResource("6_base")]\n'
             f'transform = {translate((-16, 1.2, 0))}\nflag = NodePath("../RedFlag")')
nodes.append('[node name="BlueBase" parent="." node_paths=PackedStringArray("flag") '
             'instance=ExtResource("6_base")]\n'
             f'transform = {translate((16, 1.2, 0))}\nteam = 1\nflag = NodePath("../BlueFlag")')
nodes.append('[node name="RedFlag" parent="." instance=ExtResource("7_flag")]\n'
             f'transform = {translate((-16, 2.2, 0))}')
nodes.append('[node name="BlueFlag" parent="." instance=ExtResource("7_flag")]\n'
             f'transform = {translate((16, 2.2, 0))}')

# ----- spawn circle (cornucopia): teams alternate so team modes stay balanced -----
nodes.append('[node name="SpawnPoints" type="Node3D" parent="."]\n'
             'script = ExtResource("4_spawn")')
SPAWN_COUNT = 12
SPAWN_R = 24.0
for i in range(SPAWN_COUNT):
    a = 2 * math.pi * i / SPAWN_COUNT
    px, pz = SPAWN_R * math.cos(a), SPAWN_R * math.sin(a)
    team = i % 2
    name = f'Spawn{i + 1}'
    nodes.append(f'[node name="{name}" parent="SpawnPoints" instance=ExtResource("5_sp")]\n'
                 f'transform = {look_at_center((px, 1.3, pz))}\nteam = {team}')

# ----- assemble -----
load_steps = len(EXT) + len(sub) + 1
header = f'[gd_scene load_steps={load_steps} format=3 uid="uid://dhng3rgmsandbx"]\n'
ext_block = "\n".join(
    f'[ext_resource type="{t}" uid="{u}" path="{p}" id="{i}"]' for (t, u, p, i) in EXT)
body = header + "\n" + ext_block + "\n\n" + "\n\n".join(sub) + "\n\n" + "\n\n".join(nodes) + "\n"

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write(body)
print(f"wrote {OUT}: {len(nodes)} nodes, load_steps={load_steps}")
