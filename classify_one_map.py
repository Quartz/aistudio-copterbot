from fastai.vision import *
import sys
import os
from map_classifier import MapClassifier

if __name__ == "__main__":
    print(MapClassifier().classify_map(sys.argv[1]))
