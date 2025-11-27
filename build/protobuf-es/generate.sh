#!/bin/bash -e

# Clear the index files
touch /genproto/index.ts

# Loop through all the proto files
for f in $(find /proto -type f -name "*.proto"); do
    # Build the proto file into a typescript file
    protoc -I/proto-common:/proto $f \
        --plugin=protoc-gen-es=./node_modules/.bin/protoc-gen-es --es_out=/genproto --es_opt=target=ts \
        --plugin=protoc-gen-connect-es=./node_modules/.bin/protoc-gen-connect-es --connect-es_out=/genproto --connect-es_opt=target=ts
    
    # Get the relative path of the generated directory
    relative_path=$(realpath --relative-to=/proto $(dirname $f))
    
    # Capitalize the first letter of the directory name and remove any slashes
    namespace=$(echo "${relative_path%%/*}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
    
    # Append an export with namespace
    echo "export * as ${namespace} from './${relative_path}';" >> /genproto/index.ts
done

# Loop through all the generated TypeScript files in the /genproto folder
for f in $(find /genproto -type f -name "*.ts"); do
    # Remove the .js from the generated files
    sed -i 's/\(import.*_pb\)\.js/\1/g' $f

    # Skip index.ts files
    if [[ "$(basename $f)" == "index.ts" ]]; then
        continue
    fi

    # Create the index.ts file if it doesn't exist
    if [ ! -f "$(dirname $f)/index.ts" ]; then
        touch $(dirname $f)/index.ts
    fi

    # Append the export to the index.ts
    echo "export * from './$(basename $f .ts)';" >> $(dirname $f)/index.ts
done