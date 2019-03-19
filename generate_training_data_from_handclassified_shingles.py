import csv
from os.path import join, basename, exists


copters = {
  "N917PD": "ACB1F5",
  "N918PD": "ACB5AC",
  "N919PD": "ACB963",
  "N920PD": "ACBF73",
  "N319PD": "A36989",
  "N422PD": "A50456",
  "N414PD": "A4E445",
  "N23FH" : "A206AC",
  "N509PD": "A65CA8",
}

copters = {v: k for k, v in copters.items()}

folders = {
  "all": ["hover_train_png_all", "hover_train_png_more"],
  "hover": ["hover_train_png_more_hover_only", "hover_train_png_hover_only"]
}

import csv
with open("training_data.csv", 'w') as csvout:
  training_data = csv.writer(csvout)
  with open("shingles.csv") as csvin:
    shingles_readers = csv.reader(csvin)
    for row in shingles_readers:
      icao_hex, shingle_start_time, shingle_end_time, shingle_svg_fn, shingle_png_fn, client_count, *points = row

      if not any(map(lambda folder: exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))), folders['all'])):
        raise Exception("missing file `#{shingle_png_fn}`")
      is_hover = any(map(lambda folder: exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))), folders['hover']))

      training_data.writerow([icao_hex, copters[icao_hex], shingle_start_time, shingle_end_time, is_hover])