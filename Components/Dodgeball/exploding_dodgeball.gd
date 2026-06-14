extends Dodgeball
class_name ExplodingDodgeball

# An authored bomb pickup: a Dodgeball that starts (and respawns) armed, so it's always a
# live grenade rather than needing the bomb upgrade. All explosion behaviour lives on the
# base Dodgeball — this subclass only marks it permanently armed (via permanent_armed in
# the scene) and exists so maps can reference a clearly-named bomb prefab.
