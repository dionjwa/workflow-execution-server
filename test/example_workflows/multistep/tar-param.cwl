cwlVersion: v1.0
class: CommandLineTool
baseCommand: [tar, xf]
requirements:
  DockerRequirement:
    dockerPull: docker.io/busybox:latest
    #dockerOutputDirectory:
inputs:
  tarfile:
    type: File
    inputBinding:
      position: 1
  extractfile:
    type: string
    inputBinding:
      position: 2
outputs:
  example_out:
    type: File
    outputBinding:
      glob: $(inputs.extractfile)