from fastai.vision import *
import sys

def main():
    learn = load_learner('./models')
    img = open_image(sys.argv[1])
    pred_class,pred_idx,outputs = learn.predict(img) 
    # print (pred_class)
    # print (pred_idx)
    # print (outputs)
    return pred_class

print(main())
