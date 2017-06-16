#!/usr/bin/env python3
# code by Jon May [jonmay@isi.edu]
import argparse
import sys
import codecs
if sys.version_info[0] == 2:
  from itertools import izip
else:
  izip = zip
from collections import defaultdict as dd
import re
import os.path
import gzip
import tempfile
import shutil
import atexit
from jmutil import mkdir_p
from subprocess import check_output, check_call
import shlex
scriptdir = os.path.dirname(os.path.abspath(__file__))

reader = codecs.getreader('utf8')
writer = codecs.getwriter('utf8')

JOBS=set()
def cleanjobs():
  for job in JOBS:
    if check_call(shlex.split("qdel {}".format(job))) != 0:
      sys.stderr.write("Couldn't delete {}\n".format(job))
atexit.register(cleanjobs)

def prepfile(fh, code):
  if type(fh) is str:
    fh = open(fh, code)
  ret = gzip.open(fh.name, code) if fh.name.endswith(".gz") else fh
  if sys.version_info[0] == 2:
    if code.startswith('r'):
      ret = reader(fh)
    elif code.startswith('w'):
      ret = writer(fh)
    else:
      sys.stderr.write("I didn't understand code "+code+"\n")
      sys.exit(1)
  return ret

def addonoffarg(parser, arg, dest=None, default=True, help="TODO"):
  ''' add the switches --arg and --no-arg that set parser.arg to true/false, respectively'''
  group = parser.add_mutually_exclusive_group()
  dest = arg if dest is None else dest
  group.add_argument('--%s' % arg, dest=dest, action='store_true', default=default, help=help)
  group.add_argument('--no-%s' % arg, dest=dest, action='store_false', default=not default, help="See --%s" % arg)

def main():
  parser = argparse.ArgumentParser(description="hpc launch to rescore n-best lists with a given model",
                                   formatter_class=argparse.ArgumentDefaultsHelpFormatter)
  addonoffarg(parser, 'debug', help="debug mode", default=False)
  parser.add_argument("--input", "-i", help="input directory containing *.src.hyp, *.trg.ref, weights.final for each set for a language")
  parser.add_argument("--outfile", "-o", nargs='?', type=argparse.FileType('w'), default=sys.stdout, help="output file")
  parser.add_argument("--model", "-m", help="path to zoph trained model")
  parser.add_argument("--model_nums", "-n", nargs='+', type=int, default=[1,2,3,4,5,6,7,8], help="which models to use")
  parser.add_argument("--dev", "-d", type=str, default="dev", help="set to optimize on")
  parser.add_argument("--label", "-l", type=str, default="x", help="label for job names")
  parser.add_argument("--eval", "-e", nargs='+', type=str, default=["dev", "test", "syscomb"], help="sets to evaluate on")
  parser.add_argument("--root", "-r", help="path to put outputs")
  parser.add_argument("--width", "-w", type=int, default=5, help="how many pieces to split each rescore job")
  parser.add_argument("--suffix", "-S", help="goes on the end of final onebest", default="onebest.rerank")
  parser.add_argument("--rescore_single", default=os.path.join(scriptdir, "rescore_split.py"), help="rescore script")
  parser.add_argument("--convert", default=os.path.join(scriptdir, "nmtrescore2sbmtnbest.py"), help="adjoin scores")
  parser.add_argument("--pipeline", default='/home/nlg-02/pust/pipeline-2.22', help="sbmt pipeline")
  parser.add_argument("--runrerank", default='runrerank.sh', help="runrerank script")
  addonoffarg(parser, 'skipnmt', help="assume nmt results already exist and skip them", default=False)

  workdir = tempfile.mkdtemp(prefix=os.path.basename(__file__), dir=os.getenv('TMPDIR', '/tmp'))

  try:
    args = parser.parse_args()
  except IOError as msg:
    parser.error(str(msg))

  def cleanwork():
    shutil.rmtree(workdir, ignore_errors=True)
  if args.debug:
    print(workdir)
  else:
    atexit.register(cleanwork)

  outfile = prepfile(args.outfile, 'w')
  mkdir_p(args.root)
  datasets = set(args.eval)
  datasets.add(args.dev)

  combineids = []
  adjoins = {}
  global JOBS
  for dataset in datasets:
    jobids = []
    allscores = []
    # rescore submissions; catch jobids
    for model in args.model_nums:
      data = os.path.realpath(os.path.join(args.input, "{}.src.hyp".format(dataset)))
      scores = os.path.realpath(os.path.join(args.root, "{}.m{}.scores".format(dataset, model)))
      allscores.append(scores)
      if args.skipnmt:
        if not os.path.exists(scores):
          sys.stderr.write("ERROR: Skipping nmt but {} does not exist\n".format(scores))
          sys.exit(1)
      else:
        log = os.path.realpath(os.path.join(args.root, "{}.m{}.log".format(dataset, model)))
        cmd = "{rescore} --workdir {root}/{dataset} --splitsize {width} --model {modelroot} --modelnum {model} --datafile {data} --outfile {scores} --logfile {log}".format(model=model, rescore=args.rescore_single, modelroot=os.path.realpath(args.model), data=data, root=args.root, dataset=dataset, scores=scores, width=args.width, log=log)
#        cmd = "qsubrun -j oe -o {root}/{dataset}.m{model}.monitor -N {label}.{dataset}.{model} -- {rescore} --model {modelroot} --modelnum {model} --datafile {data} --target {target} --scores {scores} --extra_rnn_args \"__logfile {log}\"".format(root=args.root, dataset=dataset, model=model, rescore=args.rescore_single, modelroot=os.path.realpath(args.model), source=source, target=target, scores=scores, log=log, label=args.label)
        outfile.write(cmd+"\n")
        job = check_output(shlex.split(cmd)).decode('utf-8').strip()
        JOBS.add(job)
        jobids.append(job)
      
    # combine rescores and paste in previous nbests;

    jobidstr = "-W depend=afterok:"+':'.join(jobids) if len(jobids)>=1 else ""
    scorestr = ' '.join(allscores)
    nbest = os.path.join(args.input, "{}.nbest".format(dataset))
    adjoin = os.path.join(args.root, "{}.adjoin.{}".format(dataset, args.suffix))
    adjoins[dataset] = adjoin
    cmd = "qsubrun -j oe -o {root}/{dataset}.convert.monitor -N {label}.{dataset}.convert {jobidstr} -- {convert} -i {scorestr} -a {nbest} -o {adjoin}".format(root=args.root, dataset=dataset, jobidstr=jobidstr, convert=args.convert, scorestr=scorestr, nbest=nbest, adjoin=adjoin, label=args.label)
    outfile.write(cmd+"\n")
    job = check_output(shlex.split(cmd)).decode('utf-8').strip()
    JOBS.add(job)
    combineids.append(job)

  # figure out what feature list is actually going to be (easier to just make it than catch output of combineid)
  featels = ' '.join(["nmt_{}".format(x) for x in range(len(args.model_nums))])
  # run actual rerank
  decodestr = ' '.join([adjoins[x] for x in args.eval])
  combineidstr = ':'.join(combineids)
  cmd="qsubrun -q isi -l walltime=0:10:00 -j oe -o {root}/rescore.monitor -N {label}.rescore -W depend=afterok:{combineidstr} -- {rerank} -S {suffix} -f \"{featels}\" -w {weights} -r {devref} -o {root} -t {devadj} {decodestr}".format(root=args.root, combineidstr=combineidstr, suffix=args.suffix, rerank=os.path.join(args.pipeline, args.runrerank), featels=featels, weights=os.path.join(args.input, "weights.final"), devref=os.path.join(args.input, "{}.trg.ref".format(args.dev)), devadj=adjoins[args.dev], decodestr=decodestr, label=args.label)
  outfile.write(cmd+"\n")
  job = check_output(shlex.split(cmd)).decode('utf-8').strip()
  JOBS.add(job)
  outfile.write(job+"\n")
  # (TODO: run bleu)

  # no more atexit job deletion
  JOBS = []
if __name__ == '__main__':
  main()