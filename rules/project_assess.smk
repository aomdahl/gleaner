# load modules
shell.prefix("module load gcc/5.5.0; module load R;") 
# configurations
configfile: "config/config.yaml"
src_path="/work-zfs/abattle4/ashton/snp_networks/gwas_decomp_ldsc/src/"
#For later:
output_type =["loadings", "factors", "weights"]
#make things better with the checkpoint tutorial:https://evodify.com/snakemake-checkpoint-tutorial/
rule all:
    input:
       # expand("results/seed2_thresh0.9_h2-0.1_vars0.01/ldsc_enrichment/F{factor}.multi_tissue.cell_type_results.txt", factor=["1","2","3","4","5","6","7", "8", "9", "10", "11", "12", "13","14","15"])
        "results/seed2_thresh0.9_h2-0.1_vars0.01/ldsc_enrichment/fdr_heatmap.png"

rule hapmap_reference: #get the list of hapmap snps for extraction, omitting HLA region
    input:
    output:
        "data/hm3_no_hla.txt"
    shell:
        """
        wget https://data.broadinstitute.org/alkesgroup/LDSCORE/weights_hm3_no_hla.tgz -p data/
        tar -xvzf data/weights_hm3_no_hla.tgz
        for i in "factorization_data/{identifier}.factors.txt"{{1..22}}; do zcat data/weights_hm3_no_hla/weights.${{i}}.l2.ldscore.gz | tail -n +2 | awk '{{print $1":"$3"\t"$2}}' >> {output}; done
        """

rule project:
    input:
        factors="factorization_data/{identifier}.factors.txt",
        variants="gwas_extracts/{identifier}/full_hapmap3_snps.z.tsv" #fixed, for now.
        #variants="gwas_extracts/seed{seedn}_thresh{thresh}_h2-{h2}_vars{pval}/full_hapmap3_snps.z.tsv" #fixed, for now.
    output:
        "results/{identifier}/projected_hapmap3_loadings.txt"
    params:
    run:
        shell("Rscript {src_path}/projectSumStats.R --output {output} --factors {input.factors} --sumstats {input.variants} --id_type 'RSID' --no_rownames")

checkpoint prep_enrichment: #format the outputed factors for enrichment analysis
    input:
        hapmap_list="/work-zfs/abattle4/ashton/reference_data/hapmap_chr_ids.txt",
        projections="results/{identifier}/projected_hapmap3_loadings.txt",
        sample_counts="/work-zfs/abattle4/ashton/snp_networks/gwas_decomp_ldsc/gwas_extracts/seed2_thresh0.9_h2-0.1_vars1e-5/full_hapmap3_snps.n.tsv"

    output:
        directory("results/{identifier}/loading_ss_files")
    params:
        "results/{identifier}/loading_ss_files/"
    shell:
        """
            mkdir -p {output}
            Rscript {src_path}/buildSumStats.R --projected_loadings {input.projections} --samp_file {input.sample_counts} --hapmap_list {input.hapmap_list} --output {params} --normal_transform
        """

rule download_enrichment_refs:
    input:
    output:
        "ldsc_reference/Multi_tissue_gene_expr.ldcts",
        expand("ldsc_reference/weights_hm3_no_hla/weights.{chr}.l2.ldscore.gz", chr = range(1,23))
    shell:
        """
            mkdir -p ldsc_reference
            cd ldsc_reference
            wget https://data.broadinstitute.org/alkesgroup/LDSCORE/LDSC_SEG_ldscores/Multi_tissue_gene_expr_1000Gv3_ldscores.tgz
            wget https://data.broadinstitute.org/alkesgroup/LDSCORE/1000G_Phase3_baseline_ldscores.tgz
            wget https://data.broadinstitute.org/alkesgroup/LDSCORE/weights_hm3_no_hla.tgz
            tar -xvzf Multi_tissue_gene_expr_1000Gv3_ldscores.tgz
            tar -xvzf 1000G_Phase3_baseline_ldscores.tgz
            tar -xvzf weights_hm3_no_hla.tgz
        """

#tis_ref may be either "Multi_tissue_chromatin" or Multi_tissue_gene_expr"
rule ldsc_enrichment: #just run for one, then call on the input.
    input:
        ss="results/{identifier}/loading_ss_files/{factor}.sumstats.gz",
        ldsc_ref ="ldsc_reference/{tis_ref}.ldcts"
    output:
        "results/{identifier}/ldsc_enrichment_{tis_ref}/{factor}.multi_tissue.cell_type_results.txt",
        "results/{identifier}/ldsc_enrichment_{tis_ref}/{factor}.multi_tissue.log"
    params:
        "results/{identifier}/ldsc_enrichment_{tis_ref}/{factor}.multi_tissue"
    shell:
        """
        cd ldsc_reference
        python /work-zfs/abattle4/ashton/genomics_course_2020/project_2/ldsc/ldsc.py \
        --h2-cts ../{input.ss} \
        --ref-ld-chr 1000G_EUR_Phase3_baseline/baseline. \
        --out ../{params} \
        --ref-ld-chr-cts ../{input.ldsc_ref} \
        --w-ld-chr weights_hm3_no_hla/weights.
        cd ../
        """

def aggregate_factors(wildcards):
    checkpoint_output = checkpoints.prep_enrichment.get(**wildcards).output[0]
    factor_numbers = glob_wildcards(f"{checkpoint_output}/F{{factor}}.sumstats.gz").factor
    print(factor_numbers)
    ldsc_files=expand("results/{{identifier}}/ldsc_enrichment_{{tis_ref}}/F{fn}.multi_tissue.cell_type_results.txt", fn = factor_numbers)
    print(ldsc_files)
    return ldsc_files



rule ldsc_visualize:
    input:
       aggregate_factors
    output:
        "results/{identifier}/ldsc_enrichment_{tis_ref}/full_heatmap.png", "results/{identifier}/ldsc_enrichment_{tis_ref}/fdr_0.05_heatmap.png", "results/{identifier}/ldsc_enrichment_{tis_ref}/fdr_0.01_heatmap.png"
    params:
        "results/{identifier}/ldsc_enrichment_{tis_ref}/"
    shell:
        """
            echo {input}
            Rscript {src_path}/visualizeLDSC.R --input_dir {params} --plot_type "fdr_sig" --output {output[1]} --fdr 0.05
            Rscript {src_path}/visualizeLDSC.R --input_dir {params} --plot_type "fdr_sig" --output {output[2]} --fdr 0.01
            Rscript {src_path}/visualizeLDSC.R --input_dir {params} --plot_type "horizontal" --output {output[0]}
        """

rule factors_assessment:
#This isn't perfect. For a cleaner run of this, try:
# bash src/runOnCustomOnes.sh ./factorization_run_lists/7_k_runlist.txt
#where 7_k_runlist.txt is a list of all of the factorizations to analyze.
#In the future, I would like to have this step nicely snakemaked....
    input: #a bit hacky at the moment, but whatever...
        tiss_dir = "results/{identifier}/ldsc_enrichment_{tis_ref}/",
        trait_names = "/work-zfs/abattle4/ashton/snp_networks/gwas_decomp_ldsc/trait_selections/seed2_thresh0.9_h2-0.1.names.tsv",
        trait_ids = "/work-zfs/abattle4/ashton/snp_networks/gwas_decomp_ldsc/trait_selections/seed2_thresh0.9_h2-0.1.studies.tsv", 
        factors= "factorization_data/{identifier}.factors.txt"
    output:  "results/{identifier}/factor_simple_scores.txt"
    params: "results/{identifier}"
    shell:
        """
            echo "Assuming using the seed 2 run...."
            Rscript /work-zfs/abattle4/ashton/snp_networks/scratch/ldsc_all_traits/src/factAssessment.R --factors {input.factors} \
                --output {params[0]} --simple --ldsc_reference  ldsc_results/seed2_thres0.9_h2-0.1/ \
                --ldsc_dir {input.tiss_dir} --trait.ids {input.trait_ids} --trait.names {input.trait_names}
        """
