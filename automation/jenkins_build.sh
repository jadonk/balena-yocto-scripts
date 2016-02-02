#!/bin/bash
set -e

MACHINE=$1
JENKINS_PERSISTENT_WORKDIR=$2
JENKINS_DL_DIR=$JENKINS_PERSISTENT_WORKDIR/shared-downloads
JENKINS_SSTATE_DIR=$JENKINS_PERSISTENT_WORKDIR/$MACHINE/sstate
MAXBUILDS=2

# Sanity checks
if [ "$#" -ne 2 ]; then
    echo "Usage: jenkins_build.sh <MACHINE> <JENKINS_PERSISTENT_WORKDIR>"
    exit 1
fi
if [ -z "$BUILD_NUMBER" ] || [ -z "$sourceBranch" ]; then
    echo "[ERROR] BUILD_NUMBER and sourceBranch variable undefined."
    exit 1
fi

# Specific staging / production flags
if [[ "$sourceBranch" == "production"* ]]; then
    BARYS_ARGUMENTS_VAR=""
else
    BARYS_ARGUMENTS_VAR="--staging"
fi

# Checkout meta-resin
if [ "$metaResinBranch" == "__ignore__" ]; then
    echo "INFO: Using the default meta-resin revision (as configured in submodules)."
else
    pushd $WORKSPACE/layers/meta-resin > /dev/null 2>&1
    git checkout --force origin/$metaResinBranch
    popd > /dev/null 2>&1
fi

# Run build
$WORKSPACE/resin-yocto-scripts/build/barys \
    --log \
    --remove-build \
    --machine "$MACHINE" \
    --supervisor-tag "$supervisorTag" \
    ${BARYS_ARGUMENTS_VAR} \
    --shared-downloads "$JENKINS_DL_DIR" \
    --shared-sstate "$JENKINS_SSTATE_DIR" \
    --rm-work

# Write deploy artifacts
BUILD_DEPLOY_DIR=$WORKSPACE/deploy
DEVICE_TYPE_JSON=$WORKSPACE/$MACHINE.json
VERSION_HOSTOS=$(cat $WORKSPACE/build/tmp/deploy/images/$MACHINE/VERSION_HOSTOS)

DEPLOY_ARTIFACT=$(jq --raw-output '.yocto.deployArtifact' $DEVICE_TYPE_JSON)
mkdir -p $BUILD_DEPLOY_DIR
rm -rf $BUILD_DEPLOY_DIR/* # do we have anything there?
mv -v $(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/$DEPLOY_ARTIFACT) $BUILD_DEPLOY_DIR/$DEPLOY_ARTIFACT
if [ -f $(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/resin-image-$MACHINE.resinhup-tar) ]; then
    mv -v $(readlink --canonicalize $WORKSPACE/build/tmp/deploy/images/$MACHINE/resin-image-$MACHINE.resinhup-tar) $BUILD_DEPLOY_DIR/resinhup-$VERSION_HOSTOS.tar
else
    echo "WARNING: No resinhup package found."
fi

mv -v $WORKSPACE/build/tmp/deploy/images/$MACHINE/VERSION $BUILD_DEPLOY_DIR
mv -v $WORKSPACE/build/tmp/deploy/images/$MACHINE/VERSION_HOSTOS $BUILD_DEPLOY_DIR
cp $DEVICE_TYPE_JSON $BUILD_DEPLOY_DIR/device-type.json
