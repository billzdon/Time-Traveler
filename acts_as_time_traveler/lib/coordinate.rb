class Coordinate
  attr_accessor :x, :y
  
  def initialize(x, y)
    self.x, self.y = x, y
  end
  
  def angle(coordinate)
    # cleanup
    delta_x = coordinate.x - self.x
    delta_y = coordinate.y - self.y
    return ((3.1415 * 2 + Math.atan2(delta_y, delta_x)) % (2 * 3.1415))
  end
  
  
  
  
  
end