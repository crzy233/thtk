add_executable(thstd
  thstd.c
  thstd.h
)
add_definitions( -g )
target_link_libraries(thstd util)
link_setargv(thstd)
install(TARGETS thstd DESTINATION bin)
install(FILES thstd.1 DESTINATION share/man/man1)
