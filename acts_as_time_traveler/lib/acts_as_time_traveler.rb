# ActsAsTimeTraveler
module ActiveRecord
  module Acts
    module TimeTraveler
      
      def self.included(base)
        base.extend ClassMethods
      end
      
      module ClassMethods
        def cattr_accessor_with_default(name, value = nil)
          cattr_accessor name.to_sym
          self.send("#{name}=", value) if value
        end
        
        def acts_as_time_traveler(options = {})
          cattr_accessor_with_default("distance_for_duration_average", {300 => 1.5, 420 => 2, 600 => 3, 900 => 5})
          cattr_accessor_with_default("angle_stepper", 0.4)
          cattr_accessor_with_default("duration_threshold", 1.0)
          cattr_accessor_with_default("k_value", 2)

          require 'net/http'
          include Geokit::Geocoders
          require 'coordinate'
          include ActiveRecord::Acts::TimeTraveler::InstanceMethods
          extend ActiveRecord::Acts::TimeTraveler::SingletonMethods
          
          attr_accessor :map_instances          

          (before_validation_on_create :auto_geocode) unless options[:auto_geocode] == false

          # custom names
          {:latitude_name => :latitude, 
            :longitude_name => :longitude, 
            :street1_name => :street1, 
            :street2_name => :street2,
            :city_name => :city,
            :state_name => :state,
            :zip_name => :zip
          }.each_pair {|name, value| cattr_accessor_with_default(name, options[value] || value)}
          
          #create an easier way to call latitude and longitude
          {:latitude_call => self.latitude_name, 
           :longitude_call => self.longitude_name
          }.each_pair do |method_name, method_call|
            define_method method_name do 
              self.send(method_call)
            end
          end
          
        end
      end
      
      module InstanceMethods

        
        def time_map(options = {})
          options[:duration] ||= 300
          options[:point_regions] ||= []
          options[:frequent_flier_miles_klass] ||= frequent_flier_miles_klass
          options[:parent] ||= self
          options[:angle_stepper] ||= angle_stepper
          options[:duration_threshold] ||= duration_threshold
          options[:k_nearest] ||= false
          
          map_instances ||= []
          map_instances << (map_instance = MapInstance.new(options))
          
          return map_instance.keeper_points
        end
        
        def find_map(options = {})
          # duration is the only finder right now
          found = map_instances.select {|map_instance| map_instance.duration = options[:duration]}
          options[:first] ? found.first : found
        end
        
        def to_geocodeable_s
            a=[self.send(self.street1_name), self.send(self.street2_name), self.send(self.city_name), self.send(self.state_name), self.send(self.zip_name)].compact
            a.delete_if { |e| !e || e == '' }
            a.join(', ')      
        end

        def pretty_print
          "#{self.send(self.street1_name)} #{self.send(self.street2_name)} #{self.send(self.city_name)}, #{self.send(self.state_name)} #{self.send(self.zip_name)}".squeeze.strip
        end
        
        def route_to(address)
          address_str = address.to_geocodeable_s
          #address_str = address
          res = Net::HTTP.get_response(URI.parse("http://maps.google.com/maps?daddr=#{address_str.url_escape}&geocode=CZqhj1E-ZJnTFZA_OwIdyPy3-A&dirflg=&saddr=#{self.to_geocodeable_s.url_escape}&f=d&hl=en&ie=UTF8&t=h&z=10&output=json"))
          response = res.body.gsub("while(1);", "")

          # json cannot parse this result because of invalid unicode
          response.pseudo_json_parse('time')
        end
        
        private
        
        def auto_geocode
          geo = Geokit::Geocoders::MultiGeocoder.geocode(self.pretty_print)
          self.send("#{self.latitude_name}=", geo.lat)
          self.send("#{self.longitude_name}=", geo.lng)
        end
        
        
      end
      
      # for attached map class
      module MapInstanceMethods
        def deserialize_map
          @kept_points ||= Marshal.load(Base64.decode64(self.class.find_by_id(self.id).points))
        end
        
        def kept_points
          @kept_points ||= deserialize_map
        end
      end
      
      module SingletonMethods
        def frequent_flier_miles(options = {})
          cattr_accessor_with_default("frequent_flier_miles_klass", options[:klass] || Map)
          named_scope :nearest_mapped_addresses, lambda {|address| {:include => frequent_flier_miles_klass.to_s.tableize,
                                                                    :joins => "LEFT JOIN #{frequent_flier_miles_klass.to_s.tableize} as #{frequent_flier_miles_klass.to_s.tableize}_for_conditions ON #{self.to_s.tableize}.id = #{frequent_flier_miles_klass.to_s.tableize}_for_conditions.parent_id AND  #{frequent_flier_miles_klass.to_s.tableize}_for_conditions.parent_type = '#{self.to_s}'", 
                                                                    :conditions => "#{frequent_flier_miles_klass.to_s.tableize}_for_conditions.id IS NOT NULL AND #{self.to_s.tableize}.id != #{address.id}", 
                                                                    :order => "POW((69.1 * (#{address.latitude_call.to_s} - #{self.to_s.tableize}.#{self.latitude_name})), 2) + POW((69.1 * (#{address.longitude_call.to_s} - #{self.to_s.tableize}.#{self.longitude_name})) * #{Math.cos(address.latitude_call/57.3).to_s},2)",
                                                                    :group => "#{self.to_s.tableize}.id",
                                                                    :limit => k_value,
                                                                    }}
          frequent_flier_miles_klass.send(:include, ActiveRecord::Acts::TimeTraveler::MapInstanceMethods)
        end
        
        def distance_between_coordinates(lat1, lat2, lng1, lng2)
          # this method will find distance between a lat and lng
          Math.acos(Math.sin(lat1) * Math.sin(lat2) + Math.cos(lat1) * Math.cos(lat2) * Math.cos(lng1 - lng2)) * (2 * Math::PI * 3995 / 360)
        end

        # this method will take a point and find another point that is a certain distance away at a particular angle
        def coordinate_for_distance(lat, lng, distance, angle)
          lat = lat.to_radians
          lng = lng.to_radians
          radial_distance = distance / 3995.0
          
          dest_lat = Math.asin(Math.sin(lat) * Math.cos(radial_distance) + Math.cos(lat) * Math.sin(radial_distance) * Math.sin(angle))
          dest_lng = lng
          unless Math.cos(lat) == 0
            dest_lng = ((lng + Math.asin(Math.cos(angle) * Math.sin(radial_distance)/Math.cos(lat)) + Math::PI) % (2 * Math::PI)) - Math::PI
          end

          return PerimeterPoint.new({:latitude => dest_lat.to_degrees, :longitude => dest_lng.to_degrees, :radius => distance, :angle => angle})
        end
        
        def time_parser(time)
          begin
            translator = {'mins' => 60, 'secs' => 1}
            split_time = time.split(' ')
            multiplier = split_time[0]
            category = split_time[1]
            translator[category] * multiplier.to_i 
          rescue
            # cannot parse the time correctly, probably ocean or mountain or non-road area
            # to deal with this, we take a walk inward and ignore the max duration
            
            false
          end
        end
        
      end
      
      # named to avoid conflicts with map as an object in rails project
      class MapInstance
        attr_accessor :point_regions, :duration, :keeper_points, :parent, :angle_stepper, :frequent_flier_miles_klass, :duration_threshold, :k_nearest, :k_nearest_maps, :k_nearest_average, :k_nearest_points
                
        def initialize(options = {})
          options.each_pair do |key, value|
            self.send("#{key}=", value) if self.respond_to?("#{key}=")
          end
          self.keeper_points = []
          
          use_k_nearest and return if self.k_nearest && !frequent_flier_miles_klass.nil?
          
          if options[:retrieve] && !self.frequent_flier_miles_klass.nil?
            self.keeper_points = self.deserialize_map
          else
            k_nearest_setup
            
            current_angle = 0
          
            while (current_angle < (Math::PI * 2 - self.angle_stepper))
              self.point_regions << PointRegion.new({:map => self, 
                                                    :angle => current_angle, 
                                                    :duration_threshold => duration_threshold, 
                                                    :recommended_distance => (self.point_regions.last.kept_point.radius rescue parent.distance_for_duration_average[self.duration])})
              current_angle = current_angle + self.angle_stepper
            end
            
            self.keeper_points = self.point_regions.collect {|region| region.kept_point}.compact
            
            serialize_map if options[:save] && !self.frequent_flier_miles_klass.nil?
          end
        end
        
        def deserialize_map
          Marshal.load(Base64.decode64(frequent_flier_miles_klass.find(:last, :conditions => {
                                                :parent_id => self.parent.id,
                                                :parent_type => self.parent.class.to_s,
                                                :duration => self.duration
                                          }).points))
        end
        
        def serialize_map
          frequent_flier_miles_klass.create({:parent_id => self.parent.id,
                                            :parent_type => self.parent.class.to_s,
                                            :duration => self.duration,
                                            :points => Base64.encode64(Marshal.dump(keeper_points))})
        end
        
        def k_nearest_setup
          self.k_nearest_maps = self.parent.class.nearest_mapped_addresses(self.parent).collect {|address| address.maps.select {|map| map.duration == self.duration}}.flatten
          self.k_nearest_points = self.k_nearest_maps.collect {|nearby_map| nearby_map.kept_points}.compact.flatten
          self.k_nearest_average = self.k_nearest_points.inject(0.0) {|sum, point| sum + point.radius}/self.k_nearest_points.length.to_f
        end
              
        def use_k_nearest
          current_angle = 0
        
          while (current_angle < (Math::PI * 2 - self.angle_stepper))
            self.point_regions << PointRegion.new({:map => self, 
                                                  :angle => current_angle, 
                                                  :duration_threshold => duration_threshold, 
                                                  :recommended_distance => self.k_nearest_average,
                                                  :k_nearest => true})
            current_angle = current_angle + self.angle_stepper
          end
          
          self.keeper_points = self.point_regions.collect {|region| region.kept_point}.compact
        end
        
        def use_k_nearest_with_k_nearest_setup
          k_nearest_setup
          use_k_nearest_without_k_nearest_setup
        end
        
        alias_method_chain :use_k_nearest, :k_nearest_setup
        
        private

        def next_angle
          self.point_regions.last.angle + self.angle_stepper
        end
      end
      
      class PointRegion
        attr_accessor :perimeter_points, :angle, :map, :satisfied, :recommended_distance, :required_maximum, :k_nearest
        
        extend ActiveRecord::Acts::TimeTraveler::SingletonMethods
        
        def initialize(options = {})
          self.angle = options[:angle] || 0
          self.map = options[:map] || nil
          self.perimeter_points = options[:perimeter_points] || []
          self.satisfied = options[:satisfied] || false
          self.recommended_distance = options[:recommended_distance] || nil
          self.required_maximum = options[:required_maximum] || false
          self.k_nearest = options[:k_nearest] || false

          #point = next_guessed_point!(self.recommended_distance)
          
          if self.k_nearest
            point.update_attributes({:kept => true})
          else
            # keep this hardcoded so that people don't mess with it and put super high res, making this app a burden
            while kept_point.nil? && self.perimeter_points.length < 10
              point = next_point!((point.radius rescue self.recommended_distance))
              point.update_attributes({:duration => self.class::time_parser((self.map.parent.route_to(point.address)))})
              if !point.duration # invalid point
                self.required_maximum = true
                self.recommended_distance = point.radius - 0.05
              end
            end
          end
        end
        
        def kept_point
          self.perimeter_points.select {|point| point.kept}.first
        end
        
        def next_guessed_point!(distance = nil)
          point = self.class::coordinate_for_distance(self.map.parent.latitude_call, self.map.parent.longitude_call, distance, self.angle)
          coordinate = Coordinate.new(point.latitude, point.longitude)
          distances = []
          self.map.k_nearest_maps.each do |nearby_map|
            nearby_map_coordinate = Coordinate.new(nearby_map.parent.latitude_call, nearby_map.parent.longitude_call)
            angle_to_point = nearby_map_coordinate.angle(coordinate)
            points = nearby_map.kept_points.sort_by_angle_difference(angle_to_point)
            distances << points.first.radius
          end
          average_distance = distances.inject(0,&:+) / distances.length
          point = self.class::coordinate_for_distance(self.map.parent.latitude_call, self.map.parent.longitude_call, average_distance, self.angle)
          point.update_attributes({:point_region => self, :required_maximum => self.required_maximum})
          self.perimeter_points << point
          return point
        end
        
        # if there is a required max point, use the distance here regardless
        def next_point!(distance = nil)
          distance_for_location = distance
          (distance_for_location = (sample_point_distance(self.perimeter_points.last) || distance) unless self.required_maximum)
          point = self.class::coordinate_for_distance(self.map.parent.latitude_call, self.map.parent.longitude_call, distance_for_location, self.angle)
          point.update_attributes({:point_region => self, :required_maximum => self.required_maximum})
          self.perimeter_points << point
          point
        end

        # this method is within region now... although it currently just accesses a point, it will access more info in the future
        def sample_point_distance(point) # this method will get far more complex
          point.radius + rand * (self.map.duration - point.duration) * 0.01 rescue nil
        end
      end
      
      class PerimeterPoint
        include Geokit::Geocoders
        
        attr_accessor :latitude, :longitude, :radius, :duration, :kept, :point_region, :required_maximum, :angle
        alias_method :distance, :radius
        # can change for each instance

        def initialize(options = {})
          options.each_pair do |key, value|
            self.send("#{key}=", value) if self.respond_to?("#{key}=")
          end
          instance_variables.each {|v| v ||= 0}
        end
        
        def update_attributes(options = {})
          options.each_pair do |key, value|
            self.send("#{key}=", value) if self.respond_to?("#{key}=")
          end
          self.point_region.satisfied = true if kept && !options[:duration].nil?
        end
        
        def kept
          @kept ||= self.required_maximum ? ((self.duration < self.point_region.map.duration) rescue false) : (((self.point_region.map.duration - self.duration).abs < self.point_region.map.duration_threshold) rescue false)
        end
        
        def address
          Geokit::Geocoders::MultiGeocoder.do_reverse_geocode(latlng)
        end
        
        def latlng
          @latlng ||= "#{self.latitude},#{self.longitude}"
        end
        
        def radius
          @radius ||= distance_between_coordinates(self.latitude, self.point_region.map.parent.latitude_call, self.longitude, self.point_region.map.parent.longitude_call)
        end
        
      end
    
    end
  end
end



class String
  def url_escape
      self.gsub(/([^ a-zA-Z0-9_.-]+)/nu) do
      '%' + $1.unpack('H2' * $1.size).join('%').upcase
      end.tr(' ', '+')
  end
  
  def pseudo_json_parse(element)
    flag = false
    self.split(":").each do |json_variable|
      if flag
        json_variable.gsub!("\"", "")
        variable = json_variable.split(",")[0]
        return variable
      elsif json_variable.include?(element)
        flag = true
      end
    end
  end
end

class Float
  def to_radians
    self / 180.0 * Math::PI
  end
  
  def to_degrees
    self / Math::PI * 180.0
  end
end

class Hash
  def to_mod
    hash = self
    Module.new do
      hash.each_pair do |key, value|
        define_method key do
          value
        end
      end
    end
  end
end

class Array
  def sort_by_angle_difference(angle, options = {})
    self.sort!{|a,b|[(a.send(:angle) - angle).abs, (a.send(:angle) - (angle + Math::PI * 2)).abs].min <=> [(b.send(:angle) - angle).abs, (a.send(:angle) - (angle + 2 * Math::PI)).abs].min}
  end
end
