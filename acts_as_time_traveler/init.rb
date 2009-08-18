# Include hook code here
require 'acts_as_time_traveler'

ActiveRecord::Base.send(:include, ActiveRecord::Acts::TimeTraveler)

