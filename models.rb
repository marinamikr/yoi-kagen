require 'bundler/setup'
Bundler.require

db_config = YAML.load(ERB.new(File.read('config/database.yml')).result, aliases: true)
ActiveRecord::Base.establish_connection(db_config[ENV['RACK_ENV'] || 'development'])

class AnalysisLog < ActiveRecord::Base
end

class User < ActiveRecord::Base
end

class Friend < ActiveRecord::Base
end