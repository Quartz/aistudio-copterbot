require 'twitter'
require 'mysql2'
require 'date'
require 'time'
require 'yaml'
require 'net/http'
require 'restclient'
require 'aws-sdk-s3'

prod_mapping_interval =15  # min, should be 15
mapping_interval = ENV["NEVERTWEET"] || ENV["NEVERTWEET"] ? 15 : prod_mapping_interval
delay = 0 # min, default 5 min

copters = {
  "N917PD" => "ACB1F5",
  "N918PD" => "ACB5AC",
  "N919PD" => "ACB963",
  "N920PD" => "ACBF73",
  "N319PD" => "A36989",
  "N422PD" => "A50456",
  "N414PD" => "A4E445",
  "N23FH"  => "A206AC",
}

SCREENSHOTTER = :chrome # {:chrome, :batik}

# select hex(icao_addr), count(*) from squitters where hex(icao_addr) in ('AAADB2','ACB1F5', 'ACB5AC', 'ACB963', 'ACBF73', 'A36989', 'A50456', 'A4E445', 'A206AC' ) group by hex(icao_addr);



BUCKET = 'qz-aistudio-jbfm-scratch'

begin
  additional_aircraft_str = Net::HTTP.get(URI("https://gist.githubusercontent.com/jeremybmerrill/65f3538b59032b3d66cd55165eec26b8/raw/64c78bca212c828787dc9a7eb0b26697e9fb67c4/planes.txt"))
  additional_aircraft = Hash[*additional_aircraft_str.split("\n").map{|line| line.split(",")}.flatten(1)]
  puts additional_aircraft
rescue
  additional_aircraft = {}
end
aircraft = copters.merge additional_aircraft

mysqlclient = Mysql2::Client.new(
  :host => ENV['MYSQLHOST'],
  :port => ENV['MYSQLPORT'],
  :username => ENV['MYSQLUSER'] || ENV['MYSQLUSERNAME'],
  :password => ENV['MYSQLPASSWORD'],
  :database => ENV['MYSQLDATABASE'] || "dump1090"
)
unless ENV['NEVERTWEET']
	creds = YAML.load_file(File.join(File.dirname(__FILE__), "creds.yml"))
	twitterclient = Twitter::REST::Client.new do |config|
  		config.consumer_key        = creds["twitter"]["consumer_key"]
  		config.consumer_secret     = creds["twitter"]["consumer_secret"]
  		config.access_token        = creds["twitter"]["token"]
  		config.access_token_secret = creds["twitter"]["secret"]
	end
end
messages = [
  "NYPD helicopter ~NNUM~ is in the air over New York City. I last saw it at ~~TIME~~.",
  "Chop chop chop, there goes NYPD copter ~NNUM~ flyin' over. I last saw it at ~~TIME~~.",
  "I wonder what's going on? NYPD chopper ~NNUM~ is up in the air. I last saw it at ~~TIME~~."
  #........................................................................................................................................
]
non_pd_msg = "Interesting plane ~NNUM~ is flying. I last saw it at ~~TIME~~."

messages_with_neighborhoods = [
  "NYPD helicopter ~NNUM~ is in the air over ~~NEIGHBORHOODS~~. I last saw it at ~~TIME~~.",
  "Chop chop chop, there goes NYPD helicopter ~NNUM~ flyin' over ~~NEIGHBORHOODS~~. Last seen at ~~TIME~~.",
  "I wonder what's going on? NYPD helicopter ~NNUM~ is up in the air at ~~TIME~~ above ~~NEIGHBORHOODS~~."
]


def andify(list)
  return list.first if list.size <= 1 
  "#{list[0...-1].join(", ")} and #{list[-1]}"
end

aircraft.each do |nnum, icao|
  begin
    # parsed_time is the current time on the rpi, so regardless of the garbage given by the airplane, that should work
    # however, it causes some NYPD helicopters to be tweeted too much
    # but without it, n725dt is never tweeted
    results = mysqlclient.query("SELECT *, convert_tz(parsed_time, '+00:00', 'US/Eastern') datetz FROM squitters WHERE icao_addr = conv('#{icao}', 16,10) and lat is not null and convert_tz(parsed_time, '+00:00', 'US/Eastern') > DATE_SUB(convert_tz(NOW(), '+00:00', 'US/Eastern'), interval #{mapping_interval} minute) and convert_tz(parsed_time, '+00:00', 'US/Eastern') < convert_tz(NOW(), '+00:00', 'US/Eastern') order by parsed_time desc;")
    puts "#{Time.now} results: #{results.count} (#{nnum} / #{icao})"
    next unless results.count > 0
    puts results.first["datetz"].inspect

    svg_fn = `/usr/local/bin/node #{File.dirname(__FILE__)}/../dump1090-mapper/mapify.js #{icao}`
    svg_fn.strip!
    puts "svg: #{svg_fn.inspect}"    

    begin
      neighborhood_names = `/usr/local/bin/node #{File.dirname(__FILE__)}/../dump1090-mapper/neighborhoods.js #{icao}`.strip.split("|")
    rescue StandardError => e
      neighborhood_names = nil
    end

    png_fn = svg_fn[0...-3] + "png"
    png_start_time = Time.now
    # on a t2.micro, this takes way too long and requires a ton of memory.
    # # turn the SVG into a PNG with Batik.
    if SCREENSHOTTER == :batik
      `java -jar #{File.dirname(__FILE__)}/../dump1090-mapper/batik-1.8/batik-rasterizer-1.8.jar #{svg_fn}`
    elsif SCREENSHOTTER == :chrome
      s3 = Aws::S3::Resource.new(region:'us-east-1')
      svg_s3_key = File.basename(svg_fn)
      svg_obj = s3.bucket(BUCKET).object(svg_s3_key)
      svg_obj.upload_file(svg_fn, acl: "public-read", content_type: 'image/svg+xml')
      chrome_cmd = "#{File.dirname(__FILE__)}/node_modules/puppeteer/.local-chromium/linux-609904/chrome-linux/chrome --headless --screenshot=#{png_fn} http://#{BUCKET}.s3.amazonaws.com/#{svg_fn}"
      puts chrome_cmd
      `#{chrome_cmd}`
    else
      STDERR.puts "WARNING: no screenshotter set, you won't get PNGs, just SVGs"
    end
    png_duration_secs = Time.now - png_start_time
    puts "png: #{png_fn}, generation took #{png_duration_secs}s"

    time_seen = results.first["datetz"].utc.getlocal

    if neighborhood_names.nil? || !nnum.include?("PD") 
      tweet_text = nnum.include?("PD") ? messages.sample.dup : non_pd_msg
      tweet_text.gsub!("~NNUM~", nnum)
      tweet_text.gsub!("~~TIME~~", time_seen.strftime("%-I:%M %p") )
      #                 11:15 PM
    else
      tweet_text = messages_with_neighborhoods.sample.dup
      tweet_text.gsub!("~NNUM~", nnum)
      tweet_text.gsub!("~~TIME~~", time_seen.strftime("%-I:%M %p") )
      while neighborhood_names.size
        possible_tweet_text = tweet_text.gsub("~~NEIGHBORHOODS~~", andify(neighborhood_names) )
        if possible_tweet_text.size < 140
          tweet_text = possible_tweet_text
          break
        else
          neighborhood_names.pop
        end
      end
    end
    
    puts "trying to tweet \"#{tweet_text}\" in #{delay} min"
    if !ENV["NEVERTWEET"] || !ENV["NEVERTOOT"]
      sleep delay * 60
    end
    unless ENV["NEVERTWEET"]
      twitterclient.update_with_media(tweet_text, File.new(png_fn)) 
    else
      puts "but not really tweeting"
    end
    unless ENV["NEVERTOOT"]
      media_json = RestClient.post "#{creds['botsinspace']["instance"]}/api/v1/media", {:file => File.new(png_fn)}, {:Authorization => "Bearer #{creds["botsinspace"]["access_token"]}"}
      media =  JSON.parse(media_json.body)
      status_json = RestClient.post "#{creds['botsinspace']["instance"]}/api/v1/statuses", {:status => tweet_text, :media_ids => [media["id"]], :visibility => "public"}, {:Authorization => "Bearer #{creds["botsinspace"]["access_token"]}"}
      $stderr.puts (JSON.parse(status_json.body).inspect)
    else
      puts "but not really tooting"
    end

    unless ENV['NEVERSLACK']
      s3 = Aws::S3::Resource.new(region:'us-east-1')
      png_s3_key = File.basename(png_fn)
      png_obj = s3.bucket(BUCKET).object(png_s3_key)
      png_obj.upload_file(png_fn, acl: "public-read", content_type: "image/png")

      slack_payload =  {
          "text" => tweet_text,
          "attachments": [
            {
                "fallback": "A map of #{nnum}'s flight over the NYC area.",
                "image_url": "http://#{BUCKET}.s3.amazonaws.com/#{png_s3_key}",
            }
        ]

      }
      puts "posting to slack"
      resp = RestClient.post(creds['slack']['webhook'], JSON.dump(slack_payload), headers: {"Content-Type": "application/json"})
      puts "slack's resp: #{resp}"
    end

  rescue StandardError => e
    puts e.inspect
    puts e.backtrace
  end
end
