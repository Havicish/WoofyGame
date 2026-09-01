class_name FootPrintManager
extends Node2D


class FootPrint:
  var position: Vector2
  var scale: Vector2
  var start_time: float
  var life_time: float
  var sprite: Sprite2D

  func _init(_sprite: Sprite2D, _position: Vector2, _scale: Vector2, _life_time: float) -> void:
    sprite = _sprite
    position = _position
    scale = _scale
    start_time = Time.get_ticks_msec() / 1000.0
    life_time = _life_time

  func is_expired() -> bool:
    var current_time = Time.get_ticks_msec() / 1000.0
    return (current_time - start_time) >= life_time

  func update() -> void:
    if is_expired():
      sprite.queue_free()
    else:
      var current_time = Time.get_ticks_msec() / 1000.0
      var elapsed_time = current_time - start_time
      var alpha = 1.0 - (elapsed_time / life_time) - 0.25
      sprite.modulate.a = alpha


var foot_prints: Array = []


func _process(_delta: float) -> void:
  for foot_print in foot_prints:
    foot_print.update()

  foot_prints = foot_prints.filter(func(foot_print):
    return not foot_print.is_expired()
  )


func create_foot_print(_texture: Texture2D, _position: Vector2, _scale: Vector2, _life_time: float) -> void:
  var sprite := Sprite2D.new()
  sprite.texture = _texture
  sprite.position = _position
  sprite.scale = _scale
  sprite.centered = true
  sprite.modulate.a = 0.0

  var foot_print = FootPrint.new(sprite, _position, _scale, _life_time)
  foot_prints.append(foot_print)
  add_child(foot_print.sprite)
