extends Node2D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
  for child in get_children():
    if child is GPUParticles2D:
      child.emitting = true
      child.speed_scale = 10.0
      get_tree().create_timer(1.5).timeout.connect(func():
        child.speed_scale = 1.0
      )
  
