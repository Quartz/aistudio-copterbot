

COPTERS = {
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
def aircraft
  begin
    additional_aircraft_str = Net::HTTP.get(URI("https://gist.githubusercontent.com/jeremybmerrill/65f3538b59032b3d66cd55165eec26b8/raw/64c78bca212c828787dc9a7eb0b26697e9fb67c4/planes.txt"))
    additional_aircraft = Hash[*additional_aircraft_str.split("\n").map{|line| line.split(",")}.flatten(1)]
    puts additional_aircraft
  rescue
    additional_aircraft = {}
  end
  COPTERS.merge additional_aircraft
end

SHINGLE_DURATION = 5 # minutes
SHINGLE_MIN_POINTS = 10 # minimum points in a trajectory.
SHINGLE_DURATION_SECS = SHINGLE_DURATION * 60

CHROME_PATH = if `whoami`.include?("ec2-user") 
                "#{File.dirname(__FILE__)}/node_modules/puppeteer/.local-chromium/linux-609904/chrome-linux/chrome"
              else
                "#{File.dirname(__FILE__)}/../dump1090-mapper/node_modules/puppeteer/.local-chromium/mac-641577/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
              end

def generate_shingles_for_trajectory(trajectory_rows)
  raise StandardError, "trajectory is too short (temporally) to generate shingles" if (trajectory_rows[0]['datetz'] - trajectory_rows[-1]['datetz']) < SHINGLE_DURATION_SECS
  traj_duration_secs = (trajectory_rows[0]['datetz'] - trajectory_rows[-1]['datetz']).abs 
  shingles_cnt = ((traj_duration_secs / (SHINGLE_DURATION_SECS)) * 2).to_i
  puts "shingles count: #{shingles_cnt} over #{(traj_duration_secs/60).to_i} min"
  shingles = (0..shingles_cnt).to_a.map do |i|
      shingle_start_elapsed_time = ((SHINGLE_DURATION_SECS/2.0) * i)
      shingle_end_elapsed_time  = ((SHINGLE_DURATION_SECS/2.0) * (i + 2))

      shingle_start_time = trajectory_rows[-1]['datetz'] + shingle_start_elapsed_time # trajectory_rows[-1] is the one that happened first.
      shingle_end_time = trajectory_rows[-1]['datetz'] + shingle_end_elapsed_time # trajectory_rows[-1] is the one that happened first.
      shingle_points = trajectory_rows.select{|pt| pt['datetz'] >= shingle_start_time && pt['datetz'] <= shingle_end_time }

      shingle_points
  end
  shingles.reject!{|shingle| shingle.size < SHINGLE_MIN_POINTS }
  # shingles.reject!{|shingle| shingle_duration < SHINGLE_MIN_DURATION } # TODO!!
  shingles
end

def generate_shingle_map_from_shingle(helicopter_icao_hex, nnum, shingle_start_time, shingle_end_time)
    shingle_svg_fn = "hover_train_svg/#{helicopter_icao_hex}_#{shingle_start_time.gsub(/[ \:]/, '_')}_#{shingle_end_time.gsub(/[ \:]/, '_')}.svg"
    shingle_cmd = "node ../dump1090-mapper/mapify.js #{EXCLUDE_BACKGROUND ? '--exclude-background' : ''} --n-number #{nnum} --start-time '#{shingle_start_time}' --end-time '#{shingle_end_time}' #{helicopter_icao_hex}"
    unless File.exists?(shingle_svg_fn) && File.new(shingle_svg_fn).size > 0
        puts shingle_cmd
        `#{shingle_cmd}` 
        File.rename("#{nnum}.svg", shingle_svg_fn)
    end
    shingle_png_fn = shingle_svg_fn.gsub("svg", "png")
    unless File.exists?(shingle_png_fn)
        chrome_cmd = "#{CHROME_PATH} --headless --window-size=600,600 --screenshot=#{shingle_png_fn} http://localhost:8000/#{shingle_svg_fn}  2>/dev/null"
        puts chrome_cmd
        begin
            `#{chrome_cmd}`
        rescue e
            puts "might be that headless chrome isn't accessible? change the path in training_data_maker.rb to point to a Chrome install, perhaps installed via npm install puppeteer"
            raise e 
        end
    end
    [shingle_png_fn, shingle_svg_fn]
end
