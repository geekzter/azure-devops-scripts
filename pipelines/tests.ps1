
# https://analytics.dev.azure.com/{organization}/_odata/v4.0-preview/$metadata

https://analytics.dev.azure.com/{organization}/{project}/_odata/v3.0-preview/PipelineRunActivityResults?
$apply=filter(
    Pipeline/PipelineName eq '{pipelinename}'
    and PipelineRunCompletedOn/Date ge {startdate}
    and (PipelineRunOutcome eq 'Succeed' or PipelineRunOutcome eq 'PartiallySucceeded')
    and (CanceledCount ne 1 and SkippedCount ne 1 and AbandonedCount ne 1)
    )

https://analytics.dev.azure.com/{organization}/{project}/_odata/v3.0-preview/PipelineRunActivityResults?$apply=filter((PipelineRunOutcome eq 'Succeed' or PipelineRunOutcome eq 'PartiallySucceeded') and (CanceledCount ne 1 and SkippedCount ne 1 and AbandonedCount ne 1))
https://analytics.dev.azure.com/{organization}/{project}/_odata/v3.0-preview/PipelineRunActivityResults?$apply=filter((PipelineRunCompletedOn/Date ge 2023-12-01T00:00:00-08:00) and (PipelineRunOutcome eq 'Succeed' or PipelineRunOutcome eq 'PartiallySucceeded') and (CanceledCount ne 1 and SkippedCount ne 1 and AbandonedCount ne 1))
https://analytics.dev.azure.com/{organization}/{project}/_odata/v3.0-preview/PipelineRunActivityResults?$apply=filter((PipelineRunCompletedOn/Date ge 2023-12-01T00:00:00-08:00) and (PipelineRunOutcome eq 'Succeed' or PipelineRunOutcome eq 'PartiallySucceeded') and (CanceledCount eq 0 and SkippedCount eq 0 and AbandonedCount eq 0))
https://analytics.dev.azure.com/{organization}/{project}/_odata/v4.0-preview/PipelineRunActivityResults?$apply=filter((PipelineRunCompletedOn/Date%20ge%202023-12-01T00:00:00-08:00)%20and%20(PipelineRunOutcome%20eq%20%27Succeed%27%20or%20PipelineRunOutcome%20eq%20%27PartiallySucceeded%27)%20and%20(CanceledCount%20eq%200%20and%20SkippedCount%20eq%200%20and%20AbandonedCount%20eq%200))&$expand=PipelineTask

https://analytics.dev.azure.com/{organization}/{project}/_odata/v4.0-preview/PipelineRunActivityResults?$apply=filter((PipelineRunCompletedOn/Date%20ge%202023-12-01T00:00:00-08:00)%20and%20(PipelineRunOutcome%20eq%20%27Succeed%27%20or%20PipelineRunOutcome%20eq%20%27PartiallySucceeded%27)%20and%20(CanceledCount%20eq%200%20and%20SkippedCount%20eq%200%20and%20AbandonedCount%20eq%200))&$expand=PipelineTask

https://analytics.dev.azure.com/{organization}/{project}/_odata/v4.0-preview/PipelineRunActivityResults?$apply=filter((PipelineRunCompletedOn/Date%20ge%202023-12-01T00:00:00-08:00)%20and%20(PipelineRunOutcome%20eq%20%27Succeed%27%20or%20PipelineRunOutcome%20eq%20%27PartiallySucceeded%27)%20and%20(CanceledCount%20eq%200%20and%20SkippedCount%20eq%200%20and%20AbandonedCount%20eq%200))&$expand=PipelineTask($filter=TaskDefinitionId eq c450a110-caea-4ea9-8299-297eecc70633)

https://analytics.dev.azure.com/{organization}/{project}/_odata/v4.0-preview/PipelineRunActivityResults?&$expand=PipelineTask&$apply=filter((PipelineRunCompletedOn/Date%20ge%202023-12-01T00:00:00-08:00)%20and%20(PipelineRunOutcome%20eq%20%27Succeed%27%20or%20PipelineRunOutcome%20eq%20%27PartiallySucceeded%27)%20and%20(CanceledCount%20eq%200%20and%20SkippedCount%20eq%200%20and%20AbandonedCount%20eq%200))

https://analytics.dev.azure.com/{organization}/{project}/_odata/v4.0-preview/PipelineRunActivityResults?&$expand=PipelineTask&$apply=filter(PipelineTask/TaskDefinitionId eq c450a110-caea-4ea9-8299-297eecc70633)

https://analytics.dev.azure.com/{organization}/{project}/_odata/v4.0-preview/PipelineRunActivityResults?&$expand=PipelineTask&$apply=filter((PipelineTask/TaskDefinitionId eq c450a110-caea-4ea9-8299-297eecc70633) and (PipelineRunCompletedOn/Date%20ge%202023-12-01T00:00:00-08:00)%20and%20(PipelineRunOutcome%20eq%20%27Succeed%27%20or%20PipelineRunOutcome%20eq%20%27PartiallySucceeded%27)%20and%20(CanceledCount%20eq%200%20and%20SkippedCount%20eq%200%20and%20AbandonedCount%20eq%200))

https://analytics.dev.azure.com/{organization}/{project}/_odata/v4.0-preview/PipelineRunActivityResults?&$expand=PipelineTask&$apply=filter((PipelineTask/TaskDefinitionId eq c450a110-caea-4ea9-8299-297eecc70633) and (PipelineRunCompletedOn/Date%20ge%202023-12-01T00:00:00-08:00)%20and%20(PipelineRunOutcome%20eq%20%27Succeed%27%20or%20PipelineRunOutcome%20eq%20%27PartiallySucceeded%27)%20and%20(CanceledCount%20eq%200%20and%20SkippedCount%20eq%200%20and%20AbandonedCount%20eq%200))/groupby((PipelineTask/TaskDefinitionName),aggregate($count as TotalCount))
