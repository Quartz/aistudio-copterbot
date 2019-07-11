from fastai.vision import *
import sys
import os

def classify_map(map_filename, learn=None):
    if not learn: 
        learn = load_learner(os.path.join(os.path.dirname(os.path.realpath(__file__)), 'models'))
    img = open_image(map_filename)
    pred_class,pred_idx,outputs = learn.predict(img) 
    # print (pred_class)
    # print (pred_idx)
    # print (outputs)
    print(outputs[0], file=sys.stderr)
    return pred_class


if __name__ == "__main__":
    print(classify_map(sys.argv[1]))
