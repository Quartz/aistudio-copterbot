"""
This is a one-off you'll probably never have to run because all it does is move the centerpoint from the metadata file into the shingles.csv file


"""

import os
import csv
import json

with open("shingles_with_centerpoints.csv", 'w') as csvout: 
    out = csv.writer(csvout)
    with open("shingles.csv") as csvfile:
        shingles_reader = csv.reader(csvfile)
        for row in shingles_reader:
            png_fn = row[4]
            if not os.path.exists(row[5]):
                continue
            with open(row[5]) as metadata_file:    
                metadata = json.load(metadata_file)
                centerpoint = metadata['centerpoint']
                out.writerow(row[0:6] + [centerpoint])