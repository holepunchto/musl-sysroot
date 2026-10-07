# Leave out the build records the kernel writes beside the headers.
file(COPY "${source}" DESTINATION "${destination}" FILES_MATCHING PATTERN "*.h")
