#include <iostream>

#define SAY(stuff)              \
  do                            \
  {                             \
    std::cerr << stuff << "\n"; \
  }                             \
  while (0)
