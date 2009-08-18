class Coordinate
  attr_accessor :x, :y
  
  def initialize(x, y)
    self.x, self.y = x, y
  end
  
  def angle(coordinate)
    delta_x = coordinate.x - self.x
    delta_y = coordinate.y - self.y
    local_angle = Math.atan(delta_y/delta_x).abs
    if delta_x < 0 && delta_y < 0
      local_angle = local_angle + 3.1415
    elsif delta_x > 0 && delta_y < 0
      local_angle = 3.1415 * 2 - local_angle
    elsif delta_x < 0 && delta_y > 0
      local_angle = 3.1415 - local_angle
    end
    return local_angle
  end
  
  
  
  
  
end