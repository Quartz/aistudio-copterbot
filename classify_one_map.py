from fastai.vision import *
import sys
import os

def main():
    learn = load_learner(os.path.join(os.path.dirname(os.path.realpath(__file__)), 'models'))
    img = open_image(sys.argv[1])
    pred_class,pred_idx,outputs = learn.predict(img) 
    # print (pred_class)
    # print (pred_idx)
    # print (outputs)
    print(outputs[0], file=sys.stderr)
    return pred_class

print(main())
