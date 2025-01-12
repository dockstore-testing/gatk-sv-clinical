version 1.0

import "Structs_module00a.wdl"

workflow CollectCoverage {

  input {
    ##################################
    #### required basic arguments ####
    ##################################
    File intervals
    File? blacklist_intervals
    Array[File]+ normal_bams
    Array[File]+ normal_bais
    Array[String]+ samples
    File ref_fasta_dict
    File ref_fasta_fai
    File ref_fasta
    String gatk_docker

    ##################################
    #### optional basic arguments ####
    ##################################
    File? gatk4_jar_override
    Int? preemptible_attempts

    ####################################################
    #### optional arguments for PreprocessIntervals ####
    ####################################################
    Int? padding
    Int? bin_length
    Float? mem_gb_for_preprocess_intervals

    ##############################################
    #### optional arguments for CollectCounts ####
    ##############################################
    Float? mem_gb_for_collect_counts
    Int? disk_space_gb_for_collect_counts
    Array[String]? disabled_read_filters
  }

  call PreprocessIntervals {
    input:
      intervals = intervals,
      blacklist_intervals = blacklist_intervals,
      ref_fasta = ref_fasta,
      ref_fasta_fai = ref_fasta_fai,
      ref_fasta_dict = ref_fasta_dict,
      padding = padding,
      bin_length = bin_length,
      gatk4_jar_override = gatk4_jar_override,
      gatk_docker = gatk_docker,
      mem_gb = mem_gb_for_preprocess_intervals,
      preemptible_attempts = preemptible_attempts
  }

  scatter (i in range(length(normal_bams))) {
    call CollectCounts {
      input:
        intervals = PreprocessIntervals.preprocessed_intervals,
        bam = normal_bams[i],
        bam_idx = normal_bais[i],
        sample_id = samples[i],
        ref_fasta = ref_fasta,
        ref_fasta_fai = ref_fasta_fai,
        ref_fasta_dict = ref_fasta_dict,
        gatk4_jar_override = gatk4_jar_override,
        gatk_docker = gatk_docker,
        mem_gb = mem_gb_for_collect_counts,
        disk_space_gb = disk_space_gb_for_collect_counts,
        disabled_read_filters = disabled_read_filters,
        preemptible_attempts = preemptible_attempts
    }
  }

  output {
    File preprocessed_intervals = PreprocessIntervals.preprocessed_intervals
    Array[File] counts = CollectCounts.counts
  }
}

task PreprocessIntervals {
  input {
    File? intervals
    File? blacklist_intervals
    File ref_fasta
    File ref_fasta_fai
    File ref_fasta_dict
    Int? padding
    Int? bin_length
    File? gatk4_jar_override

    # Runtime parameters
    String gatk_docker
    Float? mem_gb
    Int? disk_space_gb
    Boolean? use_ssd
    Int? cpu
    Int? preemptible_attempts
  }

  Float machine_mem_gb = select_first([mem_gb, 3.75])
  Int command_mem_mb = floor(machine_mem_gb*1000) - 500
  Boolean use_ssd_disk = select_first([use_ssd, false])

  command <<<
    set -e
    export GATK_LOCAL_JAR=~{default="/root/gatk.jar" gatk4_jar_override}

    gatk --java-options "-Xmx~{command_mem_mb}m" PreprocessIntervals \
      ~{"-L " + intervals} \
      ~{"-XL " + blacklist_intervals} \
      --sequence-dictionary ~{ref_fasta_dict} \
      --reference ~{ref_fasta} \
      --padding ~{default="0" padding} \
      --bin-length ~{default="100" bin_length} \
      --interval-merging-rule OVERLAPPING_ONLY \
      --output preprocessed_intervals.interval_list

  >>>

  runtime {
    docker: "~{gatk_docker}"
    memory: machine_mem_gb + " GiB"
    disks: "local-disk " + select_first([disk_space_gb, 40]) + if use_ssd_disk then " SSD" else " HDD"
    cpu: select_first([cpu, 1])
    preemptible: select_first([preemptible_attempts, 5])
    maxRetries: 1
  }

  output {
    File preprocessed_intervals = "preprocessed_intervals.interval_list"
  }
}

task CollectCounts {
  input {
    File intervals
    File bam
    File bam_idx
    String sample_id
    File ref_fasta
    File ref_fasta_fai
    File ref_fasta_dict
    File? gatk4_jar_override
    Array[String]? disabled_read_filters

    # Runtime parameters
    String gatk_docker
    Float? mem_gb
    Int? disk_space_gb
    Boolean use_ssd = false
    Int? cpu
    Int? preemptible_attempts
  }

  parameter_meta {
    bam: {
      localization_optional: true
    }
    bam_idx: {
      localization_optional: true
    }
  }

  Float mem_overhead_gb = 2.0
  Float machine_mem_gb = select_first([mem_gb, 12.0])
  Int command_mem_mb = floor((machine_mem_gb - mem_overhead_gb) * 1024)
  Array[String] disabled_read_filters_arr = if(defined(disabled_read_filters))
    then
      prefix(
        "--disable-read-filter ",
        select_first([disabled_read_filters])
      )
    else
      []

  command <<<
    set -euo pipefail
    export GATK_LOCAL_JAR=~{default="/root/gatk.jar" gatk4_jar_override}

    gatk --java-options "-Xmx~{command_mem_mb}m" CollectReadCounts \
      -L ~{intervals} \
      --input ~{bam} \
      --reference ~{ref_fasta} \
      --format TSV \
      --interval-merging-rule OVERLAPPING_ONLY \
      --output counts_100bp.~{sample_id}.tsv \
      ~{sep=' ' disabled_read_filters_arr}

    gzip counts_100bp.~{sample_id}.tsv
  >>>

  runtime {
    docker: "~{gatk_docker}"
    memory: machine_mem_gb + " GiB"
    disks: "local-disk " + select_first([disk_space_gb, 50]) + if use_ssd then " SSD" else " HDD"
    cpu: select_first([cpu, 1])
    preemptible: select_first([preemptible_attempts, 5])
    maxRetries: 1
  }

  output {
    File counts = "counts_100bp.~{sample_id}.tsv.gz"
  }
}

task CondenseReadCounts {
  input {
    File counts
    String sample
    Int? num_bins
    Int? expected_bin_size
    File? gatk4_jar_override

    # Runtime parameters
    String condense_counts_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1,
    mem_gb: 2.0,
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

  Float machine_mem_gb = select_first([runtime_attr.mem_gb, default_attr.mem_gb])
  Int command_mem_mb = floor(machine_mem_gb*1000) - 500

  command <<<
    set -e
    export GATK_LOCAL_JAR=~{default="/root/gatk.jar" gatk4_jar_override}
    gunzip -c ~{counts} > counts.tsv
    gatk --java-options "-Xmx~{command_mem_mb}m" CondenseReadCounts \
      -I counts.tsv \
      -O condensed_counts.~{sample}.tsv \
      --factor ~{select_first([num_bins, 20])} \
      --out-bin-length ~{select_first([expected_bin_size, 2000])}
    bgzip condensed_counts.~{sample}.tsv
  >>>

  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: machine_mem_gb + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: condense_counts_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }

  output {
    File out = "condensed_counts.~{sample}.tsv.gz"
  }
}

task CountsToIntervals {
  input {
    File counts
    String output_name

    # Runtime parameters
    String linux_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1,
    mem_gb: 2.0,
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

  command <<<
    set -euo pipefail
    zgrep "^@" ~{counts} > ~{output_name}.interval_list
    zgrep -v "^@" ~{counts} | sed -e 1d | awk -F "\t" -v OFS="\t" '{print $1,$2,$3,"+","."}' >> ~{output_name}.interval_list
  >>>

  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: linux_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }

  output {
    File out = "~{output_name}.interval_list"
  }
}
