Yet another of my weekly experiments in Forth. 

16ForthCLI was written to create a Forth that had 16 primitives written in Assembly language, and the remainder 
of the Forth dictionary written in high level Forth. It was a successful project, and I was able to experiment 
with several interesting ideas, including the ability to turn Forth words into macros, embedded within any 
definiition that used them, simply by starting a definition with I: instead of :. Ultimately I got tired of 
having to debug the code using the lldb debugger in a terminal window, and had Grok port the code over to a
GUI app so I could use the regular Xcode debugger. So, you will find the evolution of 16ForthCLI in the project
called 16Forth. This project 16ForthCLI is officially abandoned, so you can download it if you wish and change 
it to your hearts content.

If you are looking for a more complete public domain ANS 2012 Forth Standard Forth system for the Apple Mac 
M1-M5+ processors, with tools, an editor, a debugger, an assembler, a de-compiler, hyper text, Embedded sources 
for a number of benchmarks, and two validation suites and more, then take a look at 64Forth. 

https://github.com/Win32Forth/64Forth

If you simply want to experiment with a somewhat simpler Forth, then 16Forth might fill the bill. It is still for 
the Apple Mac M1-M5+ processors, but it doesn't have all the embedded Forth sources, and includes more limited 
tools and utilities.

https://github.com/Win32Forth/16Forth
