"""
Classify all files (saving on startup time) specified in a shingles CSV into yes or no from the model

So that we can get realistic centerpoints to match up to geocoded addresses 
"""

from fastai.vision import *
import os
from classify_one_map import classify_map
import csv
from fastai.vision import *
learn = load_learner(os.path.join(os.path.dirname(os.path.realpath(__file__)), 'models'))


with open("centerpoints.csv", 'w') as csvout: 
    out = csv.writer(csvout)
    with open("shingles.csv") as csvfile:
        shingles_reader = csv.reader(csvfile)
        for row in shingles_reader:
            png_fn = row[4]
            classification = classify_map(png_fn, learn)
            print(f"classification: {classification}")
            if classification:
                with open(row[5]) as metadata_file:    
                    metadata = json.load(metadata_file)
                    centerpoint = metadata['centerpoint']
                    out.writerow(row[0:6] + [centerpoint])