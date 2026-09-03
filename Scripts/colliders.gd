extends Node2D


@export var game_manager: Node


func _is_point_inside_sprite(sprite: Sprite2D, world_point: Vector2) -> bool:
  if sprite.texture == null:
    return false

  var local_point := sprite.to_local(world_point)
  var texture_size: Vector2 = sprite.texture.get_size()
  if sprite.region_enabled:
    texture_size = sprite.region_rect.size

  var rect_origin := sprite.offset
  if sprite.centered:
    rect_origin -= texture_size * 0.5

  return Rect2(rect_origin, texture_size).has_point(local_point)


func _process(delta: float) -> void:
  for obj in get_children():
    if obj is Sprite2D:
      var obj_should_be_transparent: bool = false
      for player in game_manager.get_children():
        if player is Sprite2D:
          var plr_pos = player.position
          var plr_in_obj: bool = _is_point_inside_sprite(obj, plr_pos)
          if plr_in_obj:
            obj_should_be_transparent = true
            obj.modulate.a = 0.75
            for obj2 in obj.get_children():
              if obj2.modulate.a < 1.0:
                obj2.visible = false
            break
      if not obj_should_be_transparent:
        obj.modulate.a = 1.0
        for obj2 in obj.get_children():
            if obj2.modulate.a < 1.0:
              obj2.visible = true
