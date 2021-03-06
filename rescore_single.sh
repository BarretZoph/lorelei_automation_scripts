#!/bin/bash
#PBS -q isi
#PBS -l walltime=336:00:00
#PBS -l gpus=2

set -e

tmpdir=${TMPDIR:-/tmp}
MTMP=$(mktemp -d --tmpdir=$tmpdir XXXXXX)
function cleanup() {
    rm -rf $MTMP;
}
trap cleanup EXIT

#This script was written by barret zoph for questions email barretzoph@gmail.com

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )""/"

#### Things that must be specified by user ####
SOURCE_RESCORE_FILE="" #Hard path and name of the source file being rescored (e.g. "/home/nlg/source_data.txt")
TARGET_RESCORE_FILE="" #Hard path and name of the target file being rescored (e.g. "/home/nlg/target_data.txt")
MODEL_FILE="" #Hard path and name of the model file being used for rescoring (e.g. "/home/nlg/model.nn")
SCORE_FILE="" #Name of file that scores are put (e.g. "score.txt")
MODEL_NUM="1" # model number to use (1-8)
EXTRA_RNN_ARGS="" # user-passed arguments to the RNN binary
RNN_LOCATION="${DIR}/helper_programs/ZOPH_RNN"
LOG_FILE=$PWD/logfile



# NORM=`tput sgr0`
# BOLD=`tput bold`
# REV=`tput smso`

NORM=`tput sgr0 -T screen.rxvt`
BOLD=`tput bold -T screen.rxvt`
REV=`tput smso -T screen.rxvt`

#Help function
function HELP {
    echo -e \\n"Help documentation for ${BOLD}${SCRIPT}.${NORM}"\\n
    echo "${BOLD}The following switches are required:${NORM}"
    echo "${REV}--model${NORM}  : Specify the location of the trained NMT models."
    echo "${REV}--model_num${NORM}  : Specify the number of the trained NMT model to use in rescoring."
    echo "${REV}--log_file${NORM}  : Specify the location of the log file the rnn generates." 
    echo "${REV}--source${NORM}  : Specify the location of the source data to be rescored." 
    echo "${REV}--target${NORM}  : Specify the location of the target data to be rescored." 
    echo "${REV}--scores${NORM}  : Specify the location of the generated scores files." 
    echo "${REV}--extra_rnn_args${NORM}  : Specify any additional argument string to pass to the RNN binary."
    echo "${REV}--rnn_location${NORM}  : Location of the RNN binary."
    echo -e "${REV}-h${NORM}  : Displays this help message. No further functions are performed."\\n
    echo "Example: qsubrun -q isi80 -- ${BOLD}$SCRIPT --model <trained_model> --source <rescore_source> --target <rescore_target> --scores <rescore_scores> ${NORM}" 
    exit 1
}

#Check the number of arguements. If none are passed, print help and exit.
NUMARGS=$#

if [[ $NUMARGS -lt "8" ]]; then
    echo -e \\n"Number of arguments: $NUMARGS"
    HELP
fi


### Start getopts code ###

#Parse command line flags
#If an option should be followed by an argument, it should be followed by a ":".
#Notice there is no ":" after "h". The leading ":" suppresses error messages from
#getopts. This is required to get my unrecognized option code to work.

VAR="1"
optspec=":h-:"
NUM=$(( 1 > $(($NUMARGS/2)) ? 1 : $(($NUMARGS/2)) ))
while [[ $VAR -le $NUM ]]; do
    while getopts $optspec FLAG; do
	case $FLAG in
	    -) #long flag options
		case "${OPTARG}" in
                    model)
                        echo "model = ""${!OPTIND}"     
                        MODEL_FILE="${!OPTIND}"
                        ;;
                    model_num)
                        echo "model_num = ""${!OPTIND}"     
                        MODEL_NUM="${!OPTIND}"
                        ;;
                    source)
                        echo "source = ""${!OPTIND}"
                        SOURCE_RESCORE_FILE="${!OPTIND}"
                        ;;
                    log_file)
                        echo "log_file : ""${!OPTIND}"
                        LOG_FILE="${!OPTIND}"
                        ;;
                    target)
                        echo "target = ""${!OPTIND}"
                        TARGET_RESCORE_FILE="${!OPTIND}"                
                        ;;
                    scores)
                        echo "scores = ""${!OPTIND}"
                        SCORE_FILE="${!OPTIND}"
                        ;;
                    extra_rnn_args)
                        >&2 echo "extra_rnn_args : ""${!OPTIND}"
                        EXTRA_RNN_ARGS="${!OPTIND}"                  
                        ;;      
                    rnn_location)
                        >&2 echo "rnn_location : ""${!OPTIND}"
                        RNN_LOCATION="${!OPTIND}"                  
                        ;;      

                    *) #unrecognized long flag
                        echo -e \\n"Option --${BOLD}$OPTARG${NORM} not allowed."
                        HELP    
                        ;;
		esac;;
	    h)  #show help
		HELP
		;;
	    \?) #unrecognized option - show help
		echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
		HELP
      #If you just want to display a simple error message instead of the full
      #help, remove the 2 lines above and uncomment the 2 lines below.
      #echo -e "Use ${BOLD}$SCRIPT -h${NORM} to see the help documentation."\\n
      #exit 2
		;;
	esac
    done
    VAR=$(($VAR + 1))
    shift 1  #This tells getopts to move on to the next argument.
done
### End getopts code ###



#### Run some error checks ####
#This following error checks are done below: making sure both rescoring files are the same length

check_equal_lines () {
    NUM1="$( wc -l $1 | cut -f1 -d ' ' )"
    NUM2="$( wc -l $2 | cut -f1 -d ' ' )"
    if [[ "$NUM1" != "$NUM2" ]]
    then
        echo "Error files: ${BOLD}$1${NORM} and ${BOLD}$2${NORM} are not the same length"
        exit 1
    fi      
}

check_zero_dir () {
    if [[ ! -d "$1" ]]
    then
        echo "Error directory: ${BOLD}$1${NORM} does not exist"
        exit 1
    fi
}

check_exists () {
    if [[ ! -d $1 ]]; then
        echo "Error the directory: ${BOLD}$1${NORM} does not exist"
        exit 1
    fi
}

find_longest_sent () {
    LONGEST_1=$( wc -L $1 | cut -f1 -d' ' )
    LONGEST_2=$( wc -L $2 | cut -f1 -d' ' )
    MAX_VAL=$(( $LONGEST_1 > $LONGEST_2 ? $LONGEST_1 : $LONGEST_2 ))
    echo $MAX_VAL
}

check_dir_final_char () {
    FINAL_CHAR="${1: -1}"
    if [[ $FINAL_CHAR != "/" ]]; then
        return 1
    fi
    return 0
}

check_relative_path () {
    if ! [[ $1 = /* ]]; then
        echo "Error: relative paths are not allowed for any location, ${BOLD}$1${NORM} is a relative path"
        exit 1 
    fi
}

check_zero_file () {
    if [[ ! -s "$1" ]]
    then
        echo "Error file: ${BOLD}$1${NORM} is of zero size or does not exist"
        exit 1
    fi
}

#checks to see if the parent directory exists, has directories model{1-8} and in each of those directories has a best.nn file
check_parent_structure () {
    
    if [[ -z "$1" ]]
    then
        echo "Error the flag ${BOLD}parent_model${NORM} must be specified" 
        exit 1
    fi
    
    if [[ ! -d "$1" ]]
    then
        echo "Error parent model directory: ${BOLD}$1${NORM} does not exist"
        exit 1
    fi      
    
    if [[ ! -d "$1""model""$MODEL_NUM" ]]
    then
        echo "Error directory ${BOLD}model$i${NORM} in parent model directory ${BOLD}$1${NORM} does not exist"
        exit 1
    fi
    
    if [[ ! -s $1"model"$MODEL_NUM"/best.nn" ]]
    then
        echo "Error model file ${BOLD}$1"model"$i"/best.nn"${NORM} does not exist"
        exit 1
    fi

}

check_valid_file_path () {
    VAR=$1
    DIR=${VAR%/*}   
    if [[ ! -d $DIR ]]; then
        echo "Error path for file ${BOLD}$1${NORM} does not exist"
        exit 1
    fi
}

set +e
check_dir_final_char "$MODEL_FILE"  
BOOL_COND=$?
set -e
if [[ "$BOOL_COND" == 1 ]]; then
    MODEL_FILE=$MODEL_FILE"/"
fi
check_relative_path "$SOURCE_RESCORE_FILE"
check_relative_path "$TARGET_RESCORE_FILE"
check_relative_path "$MODEL_FILE"
check_relative_path "$SCORE_FILE"
check_zero_file "$SOURCE_RESCORE_FILE"
check_zero_file "$TARGET_RESCORE_FILE"
check_valid_file_path "$LOG_FILE"
check_parent_structure "$MODEL_FILE"
check_equal_lines "$SOURCE_RESCORE_FILE" "$TARGET_RESCORE_FILE"
check_zero_dir "$MODEL_FILE"
SCORE_DIR=$(dirname "${SCORE_FILE}")
check_exists "$SCORE_DIR"
LONGEST_SENT=$( find_longest_sent "$SOURCE_RESCORE_FILE" "$TARGET_RESCORE_FILE" )

MODEL_FILE=$MODEL_FILE"model"$MODEL_NUM"/best.nn"


#### Sets up environment to run code ####
source /usr/usc/cuda/7.5/setup.sh
LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/usc/cuDNN/7.5-v5.1/lib64/
export LD_LIBRARY_PATH

#### Path to Executable ####
EXTRA_RNN_ARGS=`echo $EXTRA_RNN_ARGS | sed 's/__/--/g'`;
FINAL_ARGS="$RNN_LOCATION -f $SOURCE_RESCORE_FILE $TARGET_RESCORE_FILE $MODEL_FILE $SCORE_FILE -L $LONGEST_SENT  -m 1 $EXTRA_RNN_ARGS --tmp-dir-location $MTMP"
echo $FINAL_ARGS;
$FINAL_ARGS;

exit 0

