function setAgileSprintEndDate() {
  var weeks = parseInt($('#agile_sprint_duration').val(), 10);
  var start = $('#agile_sprint_start_date').val();
  if (!start || !(weeks >= 1)) return;

  var end = new Date(start);
  if (isNaN(end)) return;
  end.setUTCDate(end.getUTCDate() + weeks * 7 - 1);
  $('#agile_sprint_end_date').val(end.toISOString().slice(0, 10));
}

function resetAgileSprintDuration() {
  $('#agile_sprint_duration').val('');
}

$(document).ready(function() {
  $(document).on('change', '#agile_sprint_duration', setAgileSprintEndDate);
  $(document).on('change', '#agile_sprint_start_date', setAgileSprintEndDate);
  $(document).on('change', '#agile_sprint_end_date', resetAgileSprintDuration);
});
