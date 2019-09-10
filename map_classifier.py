from fastai.vision import *
import sys
import os
import csv
import sys
from torch.serialization import SourceChangeWarning

if not sys.warnoptions:
    import warnings
    warnings.filterwarnings("ignore", category=SourceChangeWarning)

class MapClassifier:
    def __init__(self, model_path=None):
        self.learn = load_learner(os.path.join(os.path.dirname(os.path.realpath(__file__)), 'models') if not model_path else model_path)

    def classify_map(self, map_filename):
        img = open_image(map_filename)
        pred_class, pred_idx, outputs = self.learn.predict(img) 
        # print (pred_class)
        # print (pred_idx)
        # print (outputs)
        print(outputs[0], file=sys.stderr)
        print(outputs[0])
        return pred_class.obj == "hover"

if __name__ == "__main__":
    print(MapClassifier().classify_map(sys.argv[1]))
