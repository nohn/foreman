class Report < ActiveRecord::Base
  belongs_to :host
  serialize :log, Puppet::Transaction::Report
  validates_presence_of :log, :host_id, :reported_at, :status
  validates_uniqueness_of :reported_at, :scope => :host_id

  def failed
    log.metrics["resources"][:failed]
  end

  def failed_restarts
    log.metrics["resources"][:failed_restarts]
  end

  def skipped
    log.metrics["resources"][:skipped]
  end

  def error?
    status > 0
  end

  def changes?
    log.metrics["changes"][:total] > 0
  end

  def config_retrival
    log.metrics["time"][:config_retrieval].round_with_precision(2)
  end

  def runtime
    log.metrics["time"][:total].round_with_precision(2)
  end

  #imports a yaml report into database
  def self.import(yaml)
    report = YAML.load(yaml)
    raise "Invalid report" unless report.is_a?(Puppet::Transaction::Report)
    logger.info "processing report for #{report.name}"
    begin
      host = Host.find_or_create_by_name report.host
      report_status = host.puppet_status = report_status(report)
      host.last_report = report.time.utc if host.last_report.nil? or host.last_report.utc < report.time.utc

      # we save the host without validation for two reasons:
      # 1. it might be auto imported, therefore might not be valid (e.g. missing partition table etc)
      # 2. we want this to be fast and light on the db.
      # at this point, the report is important, not as much of the host
      host.save_with_validation(perform_validation = false)

      self.create! :host => host, :reported_at => report.time.utc, :log => report, :status => report_status
    rescue Exception => e
      logger.warn "failed to process report for #{report.name} due to:#{e}"
    end
  end

  def self.summarise(message, type, hosts)
    hosts.each do |host|
      failed          = (host.puppet_status & 0x00000fff)
      skipped         = (host.puppet_status & 0x00fff000) >> 12
      failed_restarts = (host.puppet_status & 0x3f000000) >> 24
      no_report       = (host.puppet_status & 0x40000000) >> 30
      message << "%-30s %9d %9d %9d %9d" % [host.name, failed, failed_restarts, skipped, no_report]
      type[:failed]          +=1 if failed          > 0
      type[:failed_restarts] +=1 if failed_restarts > 0
      type[:skipped]         +=1 if skipped         > 0
      type[:no_report]       +=1 if no_report
    end
  end

  # add sort by report time
  def <=>(other)
    self.created_at <=> other.created_at
  end

  # We do not keep more than 24 hours of history in the database
  def self.expire_reports
    cond = ["reported_at < ?",(Time.now.utc - 24.hours)]
    logger.info Time.now.to_s + ": Expiring #{Report.count(:conditions => cond)} reports"
    Report.delete_all(cond)
  end

  protected

  # process the metrics
  # 0 is a good report, anything else requires attention
  def self.report_status report
      status = 0
      raise "Invalid report: can't find metrics information for #{report.host} at #{report.id}" if report.metrics.nil?
      resources = report.metrics["resources"]
      # check if the report actually contain anything interesting
      if resources[:failed] + resources[:skipped] + resources[:failed_restarts] + report.metrics["changes"][:total] > 0
        status  = resources[:failed] if resources[:failed] > 0
        # We only capture skipped errors when there are associated log entries.
        # Sometimes there are skipped entries but no errors in the messages file,
        # This can happen when having notice, alias messages etc
        status |= resources[:skipped] if resources[:skipped] > 0 and report.logs.size >0

        status |= resources[:failed_restarts] << 24 if resources[:failed_restarts] > 0
      end

      return status
  end

end
