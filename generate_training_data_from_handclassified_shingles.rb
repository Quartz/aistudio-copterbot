require 'date'
require 'time'
require 'csv'

shingles_csv = CSV.open("shingles.csv")


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

copters = Hash[copters.map(&:reverse)]

folders = {
	"all": ["hover_train_png_all", "hover_train_png_more"],
	"hover": ["hover_train_png_more_hover_only", "hover_train_png_hover_only"]
}

training_data = CSV.open("training_data.csv", 'wb')
shingles_csv.each do |row|
	icao_hex, shingle_start_time, shingle_end_time, shingle_svg_fn, shingle_png_fn, client_count, *points = row


	raise IOError, "missing file `#{shingle_png_fn}`" unless folders[:all].any?{|folder| File.exists?(File.join("hand_coded_training_data", folder, File.basename(shingle_png_fn))) }
	is_hover = folders[:hover].any?{|folder| File.exists?(File.join("hand_coded_training_data", folder, File.basename(shingle_png_fn))) }

	training_data << [icao_hex, copters[icao_hex], shingle_start_time, shingle_end_time, is_hover]
end