cwlVersion: v1.0
class: CommandLineTool
label: Example trivial wrapper for Java 7 compiler
baseCommand: javac
requirements:
  DockerRequirement:
    dockerPull: docker.io/java:7
arguments:
  - prefix: "-d"
    valueFrom: $(runtime.outdir)
inputs:
  - id: src
    type: File
    inputBinding:
      position: 1
outputs:
  - id: classfile
    type: File
    outputBinding:
      glob: "*.class"