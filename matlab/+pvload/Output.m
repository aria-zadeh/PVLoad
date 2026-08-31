classdef Output

methods (Static)

    function log = openLog(cfg, nStates)

        log = struct('Readings', "");

        if ~cfg.Out.WriteCsv
            return
        end

        log.Readings = stampedBase(cfg, "") + ".csv";

        fprintf("Logging to %s\n", log.Readings);
        fprintf("  at most %d states, written in blocks of %d.\n", ...
            min(cfg.Adapt.MaxPoints, nStates), cfg.Out.Chunk);
    end

    function append(log, results, rows, first)

        if strlength(log.Readings) == 0
            return
        end

        t = table( ...
            results.Timestamp(rows),     results.StateIndex(rows), ...
            results.Mode(rows),          results.Code1(rows), ...
            results.Code2(rows),         results.RNominal(rows), ...
            results.VoltageV(rows),      results.CurrentA(rows), ...
            results.ResistanceOhm(rows), results.PowerW(rows), ...
            results.SettleS(rows), ...
            'VariableNames', {'timestamp', 'state_index', 'mode', ...
                'u1_code', 'u2_code', 'r_nominal_ohm', 'voltage_v', ...
                'current_a', 'resistance_ohm', 'power_w', 'settle_s'});

        if first
            writetable(t, log.Readings);
        else
            writetable(t, log.Readings, 'WriteMode', 'append');
        end
    end

    function path = figurePath(log)

        path = "";
        if strlength(log.Readings) > 0
            path = replace(log.Readings, ".csv", ".png");
        end
    end

    function saveOhmsRun(cfg, plan, measured, stamps)

        if ~cfg.Out.WriteCsv
            plotOhmsRun(plan, measured, "");
            fprintf("WRITE_CSV is false, so the plot is on screen only.\n");
            return
        end

        base = stampedBase(cfg, "_ohms");

        t = table(stamps, (1:numel(plan))', [plan.Mode]', [plan.Code1]', ...
            [plan.Code2]', [plan.Resistance]', measured, ...
            'VariableNames', {'timestamp', 'state_index', 'mode', 'u1_code', ...
                'u2_code', 'r_model_ohm', 'r_measured_ohm'});
        writetable(t, base + ".csv");

        plotOhmsRun(plan, measured, base + ".png");

        fprintf("Readings: %s\n", base + ".csv");
        fprintf("Plot:     %s\n", base + ".png");
    end

end
end

function base = stampedBase(cfg, suffix)

    dir = resolvePath(cfg.Out.Dir);
    if ~isfolder(dir)
        mkdir(dir);
    end

    tag = strtrim(cfg.Out.Tag);
    if strlength(tag) > 0
        tag = "_" + tag;
    end

    stamp = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
    base  = string(fullfile(dir, "pvload_" + stamp + tag + suffix));
end

function path = resolvePath(relative)
    if isfile(relative) || isfolder(relative)
        path = char(relative);
        return
    end

    % two fileparts: this file sits in matlab/+pvload and OUT_DIR is
    % written relative to matlab/
    here = fileparts(fileparts(mfilename("fullpath")));
    path = fullfile(here, char(relative));
end

function plotOhmsRun(plan, measured, path)

    model = [plan.Resistance]';
    index = (1:numel(plan))';
    ratio = measured ./ model;
    mode  = [plan.Mode]';

    drawn = mode ~= "OPEN";
    model(~drawn) = NaN;
    shown = measured;
    shown(~drawn) = NaN;

    scaled = ratio;
    scaled(~drawn | mode == "SHORT") = NaN;

    fig = figure("Name", "PVLoad resistance sweep", "Color", "w");
    layout = tiledlayout(fig, 2, 1, "TileSpacing", "compact", ...
        "Padding", "compact");

    ax1 = nexttile(layout);
    plot(ax1, index, model, "-", "LineWidth", 1.0, ...
        "DisplayName", "model");
    hold(ax1, "on");
    plot(ax1, index, shown, ".", "MarkerSize", 6, ...
        "DisplayName", "measured");
    hold(ax1, "off");
    grid(ax1, "on");
    ylabel(ax1, "resistance, ohm");
    legend(ax1, "Location", "northwest");
    title(ax1, sprintf("%d states, J1 to J3, less the %d OPEN point(s)", ...
        numel(plan), sum(~drawn)));

    ax2 = nexttile(layout);
    plot(ax2, index, scaled, ".", "MarkerSize", 6);
    yline(ax2, 1, "-");
    grid(ax2, "on");
    xlabel(ax2, "state index, ordered by the model");
    ylabel(ax2, "meter / model");
    title(ax2, "SHORT and OPEN not shown", "FontWeight", "normal");

    linkaxes([ax1 ax2], "x");
    xlim(ax1, [find(drawn, 1, "first") find(drawn, 1, "last")]);

    if strlength(path) > 0
        exportgraphics(fig, path, "Resolution", 200);
    end

    hidden = sum(isnan(measured));
    if hidden > 0
        fprintf("%d point(s) the meter did not return are in the CSV " + ...
            "and are gaps on both axes.\n", hidden);
    end
end
