library(tidyverse)
library(DALEX)
library(ggplot2)
library(scales)
library(patchwork)

# Need to use the following branch of {ingredients}
# remotes::install_github("kevinykuo/ingredients", ref = "weights")

pins::board_register_github(name = "cork", repo = "kasaai/cork")
testing_data <- pins::pin_get("toy-model-testing-data", board = "cork")
piggyback::pb_download(file = "model_artifacts/toy-model.tar.gz", repo = "kasaai/cork")
untar("model_artifacts/toy-model.tar.gz", exdir = "model_artifacts")
toy_model <- keras::load_model_tf("model_artifacts/toy-model")

predictors <- c(
  "sex", "age_range", "vehicle_age", "make", 
  "vehicle_category", "region"
)

custom_predict <- function(model, newdata) {
  predict(model, newdata, batch_size = 10000)
}

explainer_nn <- DALEX::explain(
  model = toy_model,
  data = testing_data,
  y = testing_data$loss_per_exposure,
  weights = testing_data$exposure,
  predict_function = custom_predict,
  label = "neural_net"
)

pdp_vehicle_age <- ingredients::partial_dependency(
  explainer_nn, 
  "vehicle_age",
  N = 10000,
  variable_splits = list(vehicle_age = seq(0, 35, by = 0.1))
)

pdp_plot <- as.data.frame(pdp_vehicle_age) %>% 
  ggplot(aes(x = `_x_`, y = `_yhat_`)) + 
  geom_line() +
  ylab("Average Predicted Loss Cost") +
  theme_bw()+
  theme(axis.ticks.x = element_blank(),
        axis.text.x=element_blank(),
        axis.title.x=element_blank())

vehicle_age_histogram <- testing_data %>% 
  ggplot(aes(x = vehicle_age)) + 
  geom_histogram(alpha = 0.8) +
  theme_bw() +
  ylab("Count") +
  xlab("Vehicle Age")

pdp_plot <- pdp_plot / vehicle_age_histogram +
  plot_layout(heights = c(2, 1))

ggsave("manuscript/figures/pdp-plot.png", plot = pdp_plot)

fi <- ingredients::feature_importance(
  explainer_nn,
  loss_function = function(observed, predicted, weights) {
    sqrt(
      sum(((observed - predicted) ^ 2 * weights) /sum(weights))
    )
  },
  # weights = testing_data$exposure,
  variables = predictors,
  B = 10,
  n_sample = 50000
)

fi_plot <- fi %>% 
  as.data.frame() %>% 
  (function(df) {
    df <- df %>% 
      group_by(variable) %>% 
      summarize(dropout_loss = mean(dropout_loss))
    full_model_loss <- df %>% 
      filter(variable == "_full_model_") %>% 
      pull(dropout_loss)
    df %>% 
      filter(!variable %in% c("_full_model_", "_baseline_")) %>%
      ggplot(aes(x = reorder(variable, dropout_loss), y = dropout_loss)) +
      geom_bar(stat = "identity", alpha = 0.8) +
      geom_hline(yintercept = full_model_loss, col = "red", linetype = "dashed")+
      scale_y_continuous(limits = c(full_model_loss, NA),
                         oob = rescale_none
      ) +
      xlab("Variable") +
      ylab("Dropout Loss (RMSE)") +
      coord_flip() +
      theme_bw() +
      NULL
  })

ggsave("manuscript/figures/fi-plot.png", plot = fi_plot)

sample_row <- testing_data[1,] %>% 
  select(!!predictors)
breakdown <- iBreakDown::break_down(explainer_nn, sample_row)

df <- breakdown %>% 
  as.data.frame() %>% 
  mutate(start = lag(cumulative, default = first(contribution)),
         label = formatC(contribution, digits = 2, format = "f")) %>% 
  mutate_at("label", 
            ~ ifelse(!variable %in% c("intercept", "prediction") & .x > 0,
                     paste0("+", .x),
                     .x)) %>% 
  mutate_at(c("variable", "variable_value"),
            ~ .x %>% 
              sub("Entre 18 e 25 anos", "18-25", .) %>% 
              sub("Passeio nacional", "Domestic passener", .) %>% 
              sub("Masculino", "Male", .))

breakdown_plot <- df %>% 
  ggplot(aes(reorder(variable, position), fill = sign,
             xmin = position - 0.40, 
             xmax = position + 0.40, 
             ymin = start, 
             ymax = cumulative)) +
  geom_rect(alpha = 0.4) +
  geom_errorbarh(data = df %>% filter(variable_value != ""),
                 mapping = aes(xmax = position - 1.40,
                               xmin = position + 0.40,
                               y = cumulative), height = 0,
                 linetype = "dotted",
                 color = "blue") +
  geom_rect(
    data = df %>% filter(variable %in% c("intercept", "prediction")),
    mapping = aes(xmin = position - 0.4,
                  xmax = position + 0.4,
                  ymin = start,
                  ymax = cumulative),
    color = "black") +
  scale_fill_manual(values = c("blue", "orange", NA)) +
  coord_flip() +
  theme_bw() +
  theme(legend.position = "none") + 
  geom_text(
    aes(label = label, 
        y = pmax(df$cumulative,  df$cumulative - df$contribution)), 
    nudge_y = 10,
    hjust = "inward", 
    color = "black"
  ) +
  xlab("Variable") +
  ylab("Contribution") +
  theme(axis.text.y = element_text(size = 10))

ggsave("manuscript/figures/breakdown-plot.png", plot = breakdown_plot)
