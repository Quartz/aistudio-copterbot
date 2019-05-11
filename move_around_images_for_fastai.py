from os import makedirs
from shutil import copy2, rmtree
from os.path import join, basename, exists
import random
import pandas as pd
import csv
folders = {
  "all": ["hover_train_png_all", "hover_train_png_more", "hover_train_png_even_more"],
  "hover": ["hover_train_png_more_hover_only", "hover_train_png_hover_only", "hover_train_png_even_more_hover_only",]
}

LINES_ONLY = True

folder_path = "fastai_lines_only_input" if LINES_ONLY else "fastai_input"
rmtree(folder_path + "/", True)
hover_path = folder_path + "/train/hover"
nonhover_path = folder_path + "/train/nonhover"
test_hover_path = folder_path + "/test/hover"
test_nonhover_path = folder_path + "/test/nonhover"

makedirs(hover_path, exist_ok=True)
makedirs(nonhover_path, exist_ok=True)
makedirs(test_hover_path, exist_ok=True)
makedirs(test_nonhover_path, exist_ok=True)

hover_count = 0
test_hover_count = 0
nonhover_count = 0 
test_nonhover_count = 0

MAX_COUNT = 500

shingles_csv = pd.read_csv('shingles.csv', names=['icao_hex', 'shingle_start_time', 'shingle_end_time', 'shingle_svg_fn', 'shingle_png_fn', 'client_count', 'points'] + ['a' ]* 50)

for row in shingles_csv.sample(frac=1).values:
  icao_hex, shingle_start_time, shingle_end_time, shingle_svg_fn, shingle_png_fn, client_count, *points = row
  if LINES_ONLY:
    shingle_png_fn = join("hover_train_png_lines_only", basename(shingle_png_fn))
  else:
    shingle_png_fn = next(join("hand_coded_training_data", folder, basename(shingle_png_fn)) for folder in folders['all'] if exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))))
  if not shingle_png_fn or not exists(shingle_png_fn):
    print("missing file {}".format(shingle_png_fn))
    continue

  is_hover = any(map(lambda folder: exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))), folders['hover']))
  is_test = random.random() < 0.3

  if is_hover:
    if is_test:
      if test_hover_count < MAX_COUNT:
        copy2(shingle_png_fn, join(test_hover_path, basename(shingle_png_fn)))
        test_hover_count += 1
    else: 
      if hover_count < MAX_COUNT:
        copy2(shingle_png_fn, join(hover_path, basename(shingle_png_fn)))
        hover_count += 1
  else:
    if is_test:
      if test_nonhover_count < MAX_COUNT:
        copy2(shingle_png_fn, join(test_nonhover_path, basename(shingle_png_fn)))
        test_nonhover_count += 1
    else:
      if nonhover_count < MAX_COUNT:
        copy2(shingle_png_fn, join(nonhover_path, basename(shingle_png_fn)))
        nonhover_count += 1

# from pathlib import Path
# from fastai.vision import * 
# tfms = None
# path = Path('fastai_input')
# data = (ImageList.from_folder(path) #Where to find the data? -> in path and its subfolders
#         .split_by_rand_pct()              #How to split in train/valid? -> do it *randomly* (Not by folder)
#         .label_from_folder()            #How to label? -> depending on the folder of the filenames
#         .transform(tfms, size=600)       #Data augmentation? -> use tfms with a size of 600, because they all are
#         .add_test_folder("test")
#         .databunch(bs=16))

