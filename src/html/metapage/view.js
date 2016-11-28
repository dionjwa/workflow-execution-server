var urlDisplay = document.getElementById("git_url");
// console.log('QueryString', QueryString);
urlDisplay.innerHTML = QueryString.git;

function updateInputs() {
  var inputs = metaframe.getInputs();
  metaframe.log('updateInputs ' + JSON.stringify(inputs).substr(0, 200));
  // Find a <table> element with id="myTable":
  var table = document.getElementById("table-inputs");
  $('#table-inputs tbody').empty();

  var i = 1;
  for (inputKey in inputs) {
    var row = table.insertRow(i++);
    var idCell = row.insertCell(0);
    idCell.innerHTML = inputKey;
    row.insertCell(1);
    var valueCell = row.insertCell(2);
    try {
      var s = JSON.stringify(inputs[inputKey]);
      s = s.substr(0, 100);
      valueCell.innerHTML = s;
    } catch(err) {
      metaframe.error(err);
    }
  }
}

function updateOutputs() {
  var outputs = metaframe.getOutputs();
  metaframe.log('updateOutputs ' + JSON.stringify(outputs).substr(0, 200));
  // Find a <table> element with id="myTable":
  var table = document.getElementById("table-outputs");
  $('#table-outputs tbody').empty();

  var i = 1;
  for (outputKey in outputs) {
    var row = table.insertRow(i++);
    var idCell = row.insertCell(0);
    idCell.innerHTML = outputKey;
    row.insertCell(1);
    var valueCell = row.insertCell(2);
    try {
      var s = JSON.stringify(outputs[outputKey]);
      s = s.substr(0, 100);
      valueCell.innerHTML = s;
    } catch(err) {
      metaframe.error(err);
    }
  }
}

metaframe.onRemoteMethodCall(function(requestDef) {
  if (requestDef.method == "InputPipeUpdate") {
    updateInputs();
  }
});

metaframe.on("OutputPipeUpdate", function(params) {
	metaframe.log("OutputPipeUpdate " + JSON.stringify(params));
	updateOutputs();
});