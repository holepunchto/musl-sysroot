file(GLOB loaders "${directory}/ld-musl-*.so.1")

file(REMOVE ${loaders})

file(GLOB remaining "${directory}/*")

if(NOT remaining)
  file(REMOVE_RECURSE "${directory}")
endif()
