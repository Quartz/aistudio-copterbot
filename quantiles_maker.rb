require 'mysql2'

copters = {
  "N917PD" => "ACB1F5",
  "N918PD" => "ACB5AC",
  "N919PD" => "ACB963",
  "N920PD" => "ACBF73",
  "N319PD" => "A36989",
  "N422PD" => "A50456",
  "N414PD" => "A4E445",
  "N23FH"  => "A206AC",
  "N509PD" => "A65CA8",
}

mysqlclient = Mysql2::Client.new(
  :host => ENV['MYSQLHOST'],
  :port => ENV['MYSQLPORT'],
  :username => ENV['MYSQLUSER'] || ENV['MYSQLUSERNAME'],
  :password => ENV['MYSQLPASSWORD'],
  :database => ENV['MYSQLDATABASE'] || "dump1090"
)

fields = ["ground_speed", "track", "vertical_rate", "altitude"]

N = 5

fields.each do |field|
  count = mysqlclient.query(%{
    select count(*) from squitters 
    where icao_addr in (conv('ACB1F5', 16, 10), conv('ACB5AC', 16, 10), conv('ACB963', 16, 10), conv('ACBF73', 16, 10), conv('A36989', 16, 10), conv('A50456', 16, 10), conv('A4E445', 16, 10), conv('A206AC', 16, 10), conv('A65CA8', 16, 10)) 
    and #{field} is not null;}.gsub(/\s+/, " ").strip)
  puts count.first["count(*)"].inspect

  number = count.first["count(*)"] / (N + 1)

  breaks = N.times.map do |i|
    break_ = mysqlclient.query(%{
      select #{field} from squitters 
      where icao_addr in (conv('ACB1F5', 16, 10), conv('ACB5AC', 16, 10), conv('ACB963', 16, 10), conv('ACBF73', 16, 10), conv('A36989', 16, 10), conv('A50456', 16, 10), conv('A4E445', 16, 10), conv('A206AC', 16, 10), conv('A65CA8', 16, 10)) 
      and #{field} is not null 
      order by #{field} limit 1 offset #{(i + 1) * number} ;
    }.gsub(/\s+/, " ").strip)
    break_.first[field]
  end
  puts "#{field}: #{breaks}"
end