def get_statistics_columns(p_df, p_columns):

    resume_statistic = p_df[p_columns].agg(["count", "mean", "median", "min", "max"]).transpose()

    moda = p_df[p_columns].mode().iloc[0]  # Toma solo la primera moda si hay empate
    moda.name = 'mode'
    resume_statistic['mode'] = moda
    return resume_statistic


