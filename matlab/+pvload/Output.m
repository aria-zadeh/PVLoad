classdef Output
% Where a run's numbers and figures land.
%
% Rows are appended in blocks rather than at the end, so an abort keeps
% everything up to the last block boundary; a row at a time would be
% correct and far too slow, writetable reopening the file on every call.

methods (Static)

    function log = openLog(cfg, nStates)
    % One file per run, named for when it started. Never overwritten: the
    % timestamp is what stops a second run landing on the first, and RUN_TAG is
    % what tells two runs at different illumination apart afterwards, since
    % nothing in the script knows what the lamp was doing.

        log = struct('Readings', "");

        if ~cfg.Out.WriteCsv
            return
        end

        log.Readings = stampedBase(cfg, "") + ".csv";

        fprintf("Logging to %s\n", log.Readings);
        if cfg.Adapt.Enabled
            fprintf("  at most %d states, written in blocks of %d.\n", ...
                min(cfg.Adapt.MaxPoints, nStates), cfg.Out.Chunk);
        else
            fprintf("  %d states, written in blocks of %d.\n", nStates, ...
                cfg.Out.Chunk);
        end
    end

    function append(log, results, rows, first)
    % Called as each block of states finishes, so an abort keeps what it
    % measured. The first call writes the header and the rest append.

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


    %% =====================================================================
    %  Shutdown
    %  =====================================================================

    function path = figurePath(log)
    % The figure sits beside the CSV under the same stamped name, so the two
    % halves of one run cannot drift apart. No CSV means no path, and the
    % figure is drawn on screen only.

        path = "";
        if strlength(log.Readings) > 0
            path = replace(log.Readings, ".csv", ".png");
        end
    end

    function saveOhmsRun(cfg, plan, measured, stamps)
    % CSV and plot share a stamped base name, so the two halves of one run stay
    % together and a later run cannot overwrite either.
    %
    % The figure is drawn either way. WRITE_CSV decides what reaches the disk,
    % and a mode whose whole output is a plot should not lose the plot as well.

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
% One run's files share a stamped base name, so the halves of a run stay
% together and a later run cannot overwrite either. The timestamp is what
% stops a second run landing on the first; RUN_TAG is the only record of
% the illumination.

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
% Resolved against the matlab/ folder, so the current directory does not
% matter. Two fileparts, not one: this file sits in matlab/+pvload, and
% OUT_DIR is written relative to matlab/.
    if isfile(relative) || isfolder(relative)
        path = char(relative);
        return
    end
    here = fileparts(fileparts(mfilename("fullpath")));
    path = fullfile(here, char(relative));
end

function plotOhmsRun(plan, measured, path)
% Linear axes, with the model plotted alongside because the interesting
% part is where the two part company.
%
% The sweep spans five decades, so a linear upper axes is set by the top of
% the range and everything below a kilohm sits on the x axis. The lower
% axes is what carries the bottom of the sweep. It is the ratio rather than
% a difference or a percentage because both of those are dominated by one
% end: the SHORT state models at 0.150 ohm, so any offset at all is
% thousands of a percent there, and R_AB's 20% at the top is tens of kohm.
% A ratio holds the whole range at once, and 1 is agreement.
%
% Two endpoints are left off the axes because each one sets a scale that
% hides the other 767 states. OPEN comes off both: it is the 470 kohm
% resistor rather than the ladders, and forty times the largest ladder
% state. SHORT comes off the ratio axes only: it models at 0.150 ohm, so
% the probe path alone puts its ratio near 3 while every other state sits
% within a percent of 1.
%
% Both stay in the CSV, and the labels say what is missing. This is a
% choice about the axes, not about what gets measured.
%
% Nothing else is clipped or blanked. A linear axes draws a zero or
% negative reading where a log axes would have dropped it, so the count
% below names only what the meter did not return at all.

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
