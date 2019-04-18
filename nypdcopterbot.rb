require 'twitter'
require 'mysql2'
require 'date'
require 'time'
require 'yaml'
require 'net/http'
require 'restclient'
require 'aws-sdk-s3'
require_relative "./utils"
require 'fileutils'


prod_mapping_interval = 10  # min, should be 15
dev_mapping_interval = 15
mapping_interval = ENV["NEVERTWEET"] || ENV["NEVERTOOT"] ? (ENV['MAPINTVL'] || dev_mapping_interval) : prod_mapping_interval
delay = 0 # min, default 5 min

MIN_POINTS = 3 # number of points to require before tweeting a map. probably actually ought to be more!

SCREENSHOTTER = :chrome # {:chrome, :batik}

# select hex(icao_addr), count(*) from squitters where hex(icao_addr) in ('AAADB2','ACB1F5', 'ACB5AC', 'ACB963', 'ACBF73', 'A36989', 'A50456', 'A4E445', 'A206AC' ) group by hex(icao_addr);

BUCKET = 'qz-aistudio-jbfm-scratch'

MYSQLCLIENT = Mysql2::Client.new(
  :host => ENV['MYSQLHOST'],
  :port => ENV['MYSQLPORT'],
  :username => ENV['MYSQLUSER'] || ENV['MYSQLUSERNAME'],
  :password => ENV['MYSQLPASSWORD'],
  :database => ENV['MYSQLDATABASE'] || "dump1090"
)
creds = YAML.load_file(File.join(File.dirname(__FILE__), "creds.yml"))
unless ENV['NEVERTWEET']
	twitterclient = Twitter::REST::Client.new do |config|
  		config.consumer_key        = creds["twitter"]["consumer_key"]
  		config.consumer_secret     = creds["twitter"]["consumer_secret"]
  		config.access_token        = creds["twitter"]["token"]
  		config.access_token_secret = creds["twitter"]["secret"]
	end
end

PNG_PATH = "/tmp/hover/"
FileUtils.mkdir_p(PNG_PATH)

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
  return list.first || '' if list.size <= 1 
  "#{list[0...-1].join(", ")} and #{list[-1]}"
end

def generate_shingled_maps_for_trajectory(helicopter_icao_hex, helicopter_nnum, trajectory_start_time, trajectory_end_time)
  results = MYSQLCLIENT.query(%{
    SELECT *, 
      convert_tz(parsed_time, '+00:00', 'US/Eastern') datetz, 
      conv(icao_addr, 10,16) as icao_hex
    FROM squitters 
    WHERE icao_addr = conv('#{helicopter_icao_hex}', 16,10) and 
      lat is not null
      AND parsed_time >= '#{trajectory_start_time}'
      AND parsed_time <= '#{trajectory_end_time}'
    order by parsed_time desc;}.gsub(/\s+/, " ").strip)

    puts %{shingle query: 
    SELECT *, 
      convert_tz(parsed_time, '+00:00', 'US/Eastern') datetz, 
      conv(icao_addr, 10,16) as icao_hex
    FROM squitters 
    WHERE icao_addr = conv('#{helicopter_icao_hex}', 16,10) and 
      lat is not null
      AND parsed_time >= '#{trajectory_start_time}'
      AND parsed_time <= '#{trajectory_end_time}'
    order by parsed_time desc;}.gsub(/\s+/, " ").strip
    puts "Shingle has #{results.count} points"
    begin
      shingled_trajectory = generate_shingles_for_trajectory(results.to_a)
    rescue HelicopterShinglingError
      return []
    end

    # trajectories need a stable ID, as do shingles.
    # does NNum, icao hex and start, end times do it? I suppose, right?
    shingled_trajectory.map do |shingle|
        next if shingle.length == 0
        shingle_start_time = shingle[-1]["parsed_time"].to_s.gsub(/ -0\d00/, '')
        shingle_end_time = shingle[0]["parsed_time"].to_s.gsub(/ -0\d00/, '')
        shingle_png_fn, shingle_svg_fn = generate_shingle_map_from_shingle(shingle[0]["icao_hex"], helicopter_nnum, shingle_start_time, shingle_end_time,  PNG_PATH)
        [shingle_start_time, shingle_end_time, shingle_png_fn]
    end
end

def figure_out_if_hovering(helicopter_id, helicopter_nnum, trajectory_start_time, trajectory_end_time)
  map_image_fns = generate_shingled_maps_for_trajectory(helicopter_id, helicopter_nnum, trajectory_start_time, trajectory_end_time)
  map_image_fns.map do |shingle_start_time, shingle_end_time, map_image_fn|
    puts %{python3 classify_one_map.py "#{map_image_fn}"}
    was_it_hovering = `python3 classify_one_map.py "#{map_image_fn}"` # python classify_one_map.py N920PD-2019-04-17-0900-2019-04-17-0930.png
    was_it_hovering.strip!
    puts was_it_hovering
    was_it_hovering = was_it_hovering == 'hover'
    # do something with was_it_hovering.
    [shingle_start_time, shingle_end_time, was_it_hovering]
  end
end

aircraft.each do |nnum, icao|
  begin
    # parsed_time is the current time on the rpi, so regardless of the garbage given by the airplane, that should work
    # however, it causes some NYPD helicopters to be tweeted too much
    # but without it, n725dt is never tweeted
    # TODO: should I modify dump1090-stream-parser so that one of the timing columns is current time on the DB? (e.g. with MYSQL @@current_time or whatever)
    results = MYSQLCLIENT.query(%{
      SELECT *, convert_tz(parsed_time, '+00:00', 'US/Eastern') datetz 
      FROM squitters 
      WHERE icao_addr = conv('#{icao}', 16,10) and 
        lat is not null and 
        convert_tz(parsed_time, '+00:00', 'US/Eastern') > DATE_SUB(convert_tz(NOW(), '+00:00', 'US/Eastern'), interval #{mapping_interval} minute) and 
        convert_tz(parsed_time, '+00:00', 'US/Eastern') < convert_tz(NOW(), '+00:00', 'US/Eastern') 
      order by parsed_time desc;}.gsub(/\s+/, " ").strip)
    puts "#{Time.now} results: #{results.count} (#{nnum} / #{icao})"
    next unless results.count >= 2

    svg_fn = `MAXTIMEDIFF=#{10} /usr/local/bin/node #{File.dirname(__FILE__)}/../dump1090-mapper/mapify.js --n-number #{nnum}  #{icao}`
    svg_fn.strip!
    puts "svg: #{svg_fn.inspect}"    


    metadata_fn = svg_fn.gsub(".svg", ".metadata.json")
    metadata = JSON.parse(open(metadata_fn, 'r'){|f| f.read })
    neighborhood_names = metadata["nabes"] 
    
    # not currently used, just trying not to forget about 'em.
    start_recd_time = metadata["start_recd_time"]
    end_recd_time = metadata["end_recd_time"]
    start_ac_time = metadata["start_ac_time"]
    end_ac_time = metadata["end_ac_time"]
    points_cnt = metadata["points_cnt"]

    next if points_cnt < MIN_POINTS

    png_datetime = Time.now.strftime("%Y-%m-%d_%H_%M_%S")
    png_fn = svg_fn[0...-4] + png_datetime +  ".png"
    new_metadata_fn = metadata_fn.gsub(".metadata.json", "-" + png_datetime + ".metadata.json")
    File.rename(metadata_fn, new_metadata_fn)

    png_start_time = Time.now
    # on a t2.micro, this takes way too long and requires a ton of memory.
    if SCREENSHOTTER == :batik
      # turn the SVG into a PNG with Batik.
      `java -jar #{File.dirname(__FILE__)}/../dump1090-mapper/batik-1.8/batik-rasterizer-1.8.jar #{svg_fn}`
    elsif SCREENSHOTTER == :chrome
      # turn the SVG into a PNG with headless chrome
      s3 = Aws::S3::Resource.new(region:'us-east-1')
      svg_s3_key = File.basename(svg_fn)
      svg_obj = s3.bucket(BUCKET).object(svg_s3_key)
      svg_obj.upload_file(svg_fn, acl: "public-read", content_type: 'image/svg+xml')
      chrome_cmd = "#{CHROME_PATH} --headless --window-size=600,600  --disable-overlay-scrollbar --screenshot=#{png_fn} http://#{BUCKET}.s3.amazonaws.com/#{svg_fn}  2>/dev/null"
      puts chrome_cmd
      `#{chrome_cmd}`
    else
      STDERR.puts "WARNING: no screenshotter set, you won't get PNGs, just SVGs"
    end
    png_duration_secs = Time.now - png_start_time
    puts "png: #{png_fn}, generation took #{png_duration_secs}s"


    when_hovering = false
    if true # we're just not ready yet
      res = figure_out_if_hovering(icao, nnum, start_recd_time, end_recd_time)
      puts "when is it hovering? " + res.inspect
      hovering_shingles = res.select{|shingle_start, shingle_end, was_hovering| was_hovering}.map{|shingle_start, shingle_end, was_hovering| [shingle_start, shingle_end]}
      when_hovering = if hovering_shingles.size > 0
                       andify(hovering_shingles.flatten.uniq.each_slice(2).map{|a, b| "#{a} to {b}"})
                      else 
                        false
                      end
      puts "IT HOVERED: #{when_hovering}" if when_hovering
    end

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
    debug_text = "#{points_cnt} points; #{start_recd_time} to #{end_recd_time}" + (when_hovering ? when_hovering : '' )
    
    tweet_text += "AND IT WAS HOVERING" if when_hovering

    s3 = Aws::S3::Resource.new(region:'us-east-1')
    png_s3_base_key = File.basename(png_fn)
    png_s3_key = "airplanes/" + png_s3_base_key #.gsub(".png", '') + png_datetime +  ".png"
    png_obj = s3.bucket(BUCKET).object(png_s3_key)
    png_obj.upload_file(png_fn, acl: "public-read", content_type: "image/png")

    metadata_s3_base_key = File.basename(new_metadata_fn)
    metadata_s3_key = "airplanes/" + metadata_s3_base_key 
    metadata_obj = s3.bucket(BUCKET).object(metadata_s3_key)
    metadata_obj.upload_file(new_metadata_fn, acl: "public-read", content_type: "application/json")

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
      slack_payload =  {
          "text" => tweet_text + " \n " + debug_text,
          "attachments": [
            {
                "fallback": "A map of #{nnum}'s flight over the NYC area.",
                "image_url": "http://#{BUCKET}.s3.amazonaws.com/#{png_s3_key}",
            }
        ]
      }
      puts "posting to slack"
      resp = RestClient.post(creds['slack']['webhook'], JSON.dump(slack_payload), headers: {"Content-Type": "application/json"})
    end

  rescue StandardError => e
    puts e.inspect
    puts e.backtrace
  end
end
